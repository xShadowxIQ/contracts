// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Adversarial probe of the ONE path where lender principal could in principle be
///         reachable: `CreditPoolV2._slash` topping up from `reserve`, and what happens when
///         that reserve is empty. A Critical finding under BOUNTY.md is "lender principal can
///         be reached"; `totalBadDebt` is the pool's own record of exactly that, and the
///         contract documents "the reserve tops up exactly enough that the share price still
///         cannot fall; anything the reserve cannot cover is recorded, never hidden."
///
///         This suite tries hard to make `totalBadDebt != 0` or to drop the share price,
///         across many defaults, drained reserves, tiny loans, partial draws, freezes, and
///         re-vouching. If it ever succeeds, that is a Critical.
contract SlashReserveInvariants is Test {
    uint256 constant USDC = 1e6;

    CreditPoolV2 pool;
    MockUSDC usdc;
    MockIdentityRegistry reg;
    address timelock = makeAddr("timelock");

    address[] rootOwner;
    uint256[] roots;
    mapping(uint256 => uint256) rootPk;
    address[] agentOwner;
    uint256[] agents;
    uint256[] agentPk;

    function setUp() public {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        pool = new CreditPoolV2(
            IERC20(address(usdc)),
            IERC8004Identity(address(reg)),
            CreditPool(address(0)),
            timelock,
            timelock,
            CreditPoolV2.Params({
                minLoan: 1e6,
                maxLoan: 500e6,
                minTerm: 1 days,
                maxTerm: 30 days,
                grace: 3 days,
                minScoreTerm: 7 days,
                feeBps: 100,
                sponsorFeeBps: 2500,
                protocolFeeBps: 1500,
                minStake: 1e6,
                maxUtilizationBps: 9000,
                keeperBounty: 0
            })
        );
        usdc.mint(address(this), 100_000_000 * USDC);
        usdc.approve(address(pool), type(uint256).max);
        pool.seed();
        pool.deposit(50_000_000 * USDC, address(this), 0);

        for (uint256 i; i < 3; i++) {
            uint256 pk = 0xB000 + i;
            address ro = vm.addr(pk);
            rootPk[i] = pk;
            rootOwner.push(ro);
            usdc.mint(ro, 10_000_000 * USDC);
            vm.startPrank(ro);
            usdc.approve(address(pool), type(uint256).max);
            uint256 id = reg.register("");
            pool.enrollRoot(id, 5_000 * USDC); // small backing -> tight, rounding-sensitive
            vm.stopPrank();
            roots.push(id);
        }
        for (uint256 i; i < 20; i++) {
            uint256 pk = 0xD000 + i;
            agentPk.push(pk);
            usdc.mint(vm.addr(pk), 1_000_000 * USDC);
            vm.startPrank(vm.addr(pk));
            usdc.approve(address(pool), type(uint256).max);
            agents.push(reg.register(""));
            vm.stopPrank();
        }
    }

    function _consent(uint256 aid, uint256 r)
        internal
        view
        returns (CreditPoolV2.Consent memory c, bytes memory sig)
    {
        uint256 apk = agentPk[(aid % agentPk.length)];
        c = CreditPoolV2.Consent({
            agentId: aid,
            sponsorId: r,
            owner: vm.addr(apk),
            maxPremiumBps: 0,
            nonce: pool.nonces(aid),
            deadline: block.timestamp + 3650 days
        });
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(apk, pool.consentDigest(c));
        sig = abi.encodePacked(rr, ss, v);
    }

    function _vouch(uint256 ri, uint256 ai, uint256 amt) internal {
        uint256 aid = agents[ai];
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(aid, roots[ri]);
        vm.prank(rootOwner[ri]);
        try pool.vouchWithConsent(roots[ri], aid, amt, 0, c, sig) {} catch {}
    }

    function _borrow(uint256 ai, uint256 amt) internal returns (uint256) {
        uint256 aid = agents[ai];
        address o = vm.addr(agentPk[ai % agentPk.length]);
        vm.prank(o);
        try pool.borrow(aid, amt, 7 days, o, type(uint256).max) returns (uint256 l) {
            return l;
        } catch {
            return 0;
        }
    }

    function _default(uint256 lid) internal {
        if (lid == 0) return;
        CreditPoolV2.Loan memory l = pool.getLoan(lid);
        if (l.status != CreditPoolV2.LoanStatus.Active) return;
        if (block.timestamp <= l.defaultableAt) vm.warp(l.defaultableAt + 1);
        try pool.markDefault(lid) {} catch {}
    }

    function _drainReserve() internal {
        uint256 r = pool.reserve();
        if (r > 0) {
            vm.prank(timelock);
            pool.withdrawReserve(r, timelock);
        }
    }

    function _assertLendersWhole(uint256 priceBefore) internal {
        assertEq(pool.totalBadDebt(), 0, "totalBadDebt must stay 0");
        uint256 price = pool.totalAssets() * 1e18 / pool.totalShares();
        assertGe(price, priceBefore, "share price fell: lenders lost");
        assertGe(
            usdc.balanceOf(address(pool)),
            pool.poolLiquidity() + pool.reserve() + pool.unclaimedSponsorFees(),
            "cash < ledger"
        );
        for (uint256 r; r < roots.length; r++) {
            for (uint256 a; a < agents.length; a++) {
                CreditPoolV2.Agent memory ag = pool.getAgent(agents[a]);
                if (ag.sponsor == roots[r]) {
                    assertGe(
                        pool.backing(roots[r]),
                        ag.delegatedIn,
                        "backer backing < outstanding line"
                    );
                }
            }
        }
    }

    /// @dev The headline probe: many defaults against a fully drained reserve with
    ///      rounding-sized loans (1 USDG, the minimum) against minimally-backed roots.
    function test_SlashWithDrainedReserveAndMinimumLoansNeverTouchesLenders() public {
        uint256 p0 = pool.totalAssets() * 1e18 / pool.totalShares();
        _drainReserve();

        uint256 borrowed;
        for (uint256 round; round < 40; round++) {
            uint256 ai = round % agents.length;
            uint256 ri = round % roots.length;
            _vouch(ri, ai, pool.getParams().minLoan * 10);
            uint256 l = _borrow(ai, pool.getParams().minLoan); // smallest possible loan
            if (l != 0) borrowed++;
            _default(l);
            _assertLendersWhole(p0);
        }
        assertGt(borrowed, 0, "no loan was ever drawn (test vacuous)");
    }

    /// @dev Vary loan size and draw fraction so the burn's rounding lands differently.
    function test_SlashAcrossManyLoanSizesNeverTouchesLenders() public {
        uint256 p0 = pool.totalAssets() * 1e18 / pool.totalShares();
        _drainReserve();
        uint256 sizes = 9;
        for (uint256 round; round < 60; round++) {
            uint256 ai = round % agents.length;
            _vouch(0, ai, 1000 * USDC);
            uint256 amt = (round % sizes + 1) * 137 * USDC + 1; // odd, non-round amounts
            uint256 l = _borrow(ai, amt);
            _default(l);
            _assertLendersWhole(p0);
        }
    }

    /// @dev Partially draw a line then default: only the drawn part burns shares, and the
    ///      undrawn part is returned. Checks the ledger still balances.
    function test_SlashAfterPartialDrawNeverTouchesLenders() public {
        uint256 p0 = pool.totalAssets() * 1e18 / pool.totalShares();
        _drainReserve();
        for (uint256 i; i < 10; i++) {
            _vouch(0, i, 500 * USDC);
            uint256 l = _borrow(i, (i + 1) * 37 * USDC);
            _default(l);
            _assertLendersWhole(p0);
        }
    }

    /// @dev Freeze first (returns the undrawn line), then default the drawn part.
    function test_SlashAfterFreezeNeverTouchesLenders() public {
        uint256 p0 = pool.totalAssets() * 1e18 / pool.totalShares();
        _drainReserve();
        for (uint256 i; i < 10; i++) {
            _vouch(1, i, 400 * USDC);
            uint256 l = _borrow(i, 100 * USDC + i);
            vm.prank(rootOwner[1]);
            try pool.freeze(agents[i], true) {} catch {}
            _default(l);
            _assertLendersWhole(p0);
        }
    }

    /// @dev Same backer, multiple sequential loans each fully defaulted, re-vouching between.
    ///      The worst cumulative burn-down for a single stake.
    function test_RepeatedFullDefaultsAgainstOneRootNeverTouchesLenders() public {
        uint256 p0 = pool.totalAssets() * 1e18 / pool.totalShares();
        _drainReserve();
        for (uint256 round; round < 20; round++) {
            uint256 ai = round % agents.length;
            _vouch(0, ai, 1000 * USDC);
            uint256 l = _borrow(ai, 900 * USDC);
            _default(l);
            _assertLendersWhole(p0);
        }
    }

    /// @dev Fuzzed sequence of operations; the invariants hold after every step.
    function testFuzz_ArbitrarySequenceNeverProducesBadDebt(uint256 seed, uint8 steps) public {
        steps = uint8(bound(steps, 1, 60));
        uint256 p0 = pool.totalAssets() * 1e18 / pool.totalShares();
        if ((seed % 4) == 0) _drainReserve();

        for (uint256 i; i < steps; i++) {
            uint256 op = uint256(keccak256(abi.encode(seed, i))) % 5;
            uint256 ai = uint256(keccak256(abi.encode(seed, i, "a"))) % agents.length;
            uint256 ri = uint256(keccak256(abi.encode(seed, i, "r"))) % roots.length;
            if (op == 0) _vouch(ri, ai, bound(uint256(keccak256(abi.encode(seed, i, "v"))), 1, 2000) * USDC);
            else if (op == 1) _default(_borrow(ai, bound(uint256(keccak256(abi.encode(seed, i, "b"))), 1, 900) * USDC + 1));
            else if (op == 2) {
                vm.prank(rootOwner[ri]);
                try pool.freeze(agents[ai], true) {} catch {}
            } else if (op == 3) {
                vm.prank(rootOwner[ri]);
                try pool.unvouch(roots[ri], agents[ai], pool.getAgent(agents[ai]).delegatedIn) {} catch {}
            } else if ((seed + i) % 7 == 0) {
                vm.warp(block.timestamp + bound(uint256(keccak256(abi.encode(seed, i, "t"))), 1 days, 8 days));
            }
            _assertLendersWhole(p0);
        }
    }
}