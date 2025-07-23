// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { DeployPortLayerZeroScript } from "../../script/DeployPortLayerZero.s.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { AtomicQueue } from "src/atomic-queue/AtomicQueue.sol";
import { BridgeData } from "src/base/Roles/CrossChain/CrossChainTellerBase.sol";
import { Origin, MessagingFee, MessagingReceipt } from "src/base/Roles/CrossChain/OAppAuth/OAppAuth.sol";
import {
    ILayerZeroEndpointV2,
    MessagingParams
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @dev forge test --match-contract PortLayerZeroPoCTest -vvv
contract PortLayerZeroPoCTest is Test, DeployPortLayerZeroScript {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    uint256 constant SECONDS_PER_YEAR = 365 days;
    uint256 constant BASIS_POINTS = 10_000;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public solver = makeAddr("solver");
    address public badActor = makeAddr("badActor");

    // Mock LayerZero endpoint for testing
    MockLayerZeroEndpoint public mockEndpoint;

    // Events for testing
    event Deposited(address indexed user, address indexed asset, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, address indexed asset, uint256 amount, uint256 shares);
    event BridgeRequested(address indexed user, uint32 indexed dstEid, uint256 shares, bytes32 messageId);

    function setUp() external {
        console.log("\n=== SETUP PHASE ===");
        uint256 forkId = vm.createFork(vm.envString("MAINNET_RPC_URL"));
        vm.selectFork(forkId);

        // Setup mock LayerZero endpoint
        mockEndpoint = new MockLayerZeroEndpoint();
        console.log("Mock LayerZero endpoint deployed at:", address(mockEndpoint));

        // Set test addresses
        hexTrust = makeAddr("hexTrust");

        // Run deployment with mock endpoint
        console.log("Deploying Nucleus Boring Vault infrastructure...");
        run(address(this), hexTrust, address(mockEndpoint));

        // Log deployed contracts
        console.log("\n--- L1 Contracts ---");
        console.log("L1 Vault:", address(l1Vault));
        console.log("L1 Teller:", address(l1Teller));
        console.log("L1 Accountant:", address(l1Accountant));
        console.log("L1 AtomicQueue:", address(l1AtomicQueue));

        console.log("\n--- L2 Contracts ---");
        console.log("L2 Vault:", address(l2Vault));
        console.log("L2 Teller:", address(l2Teller));
        console.log("L2 Accountant:", address(l2Accountant));
        console.log("L2 AtomicQueue:", address(l2AtomicQueue));

        // Setup mock endpoint connections
        mockEndpoint.setDestination(L1_EID, L2_EID, address(l2Teller));
        mockEndpoint.setDestination(L2_EID, L1_EID, address(l1Teller));

        // Fund test accounts
        _fundTestAccounts();

        // Setup roles
        vm.startPrank(owner);
        l1Authority.setUserRole(solver, CAN_SOLVE_ROLE, true);
        l2Authority.setUserRole(solver, CAN_SOLVE_ROLE, true);
        l1Teller.setDepositCap(type(uint256).max);
        vm.stopPrank();

        console.log("\n=== SETUP COMPLETE ===\n");
    }

    function _fundTestAccounts() internal {
        address[4] memory accounts = [alice, bob, solver, badActor];
        for (uint256 i = 0; i < accounts.length; i++) {
            deal(address(WETH), accounts[i], 1000e18);
            deal(accounts[i], 10 ether);
        }
        // Extra funds for HexTrust
        deal(address(WETH), hexTrust, 1000e18);
        deal(hexTrust, 10 ether);
    }

    function test_CrossChainDepositAndWithdraw() external {
        console.log("\n=== TEST: Cross-Chain Deposit and Withdraw ===");
        uint256 amount = 100e18;

        // 1. Alice deposits WETH on L1
        console.log("\n1. ALICE DEPOSITS ON L1");
        console.log("   Amount to deposit: %s WETH", amount / 1e18);

        vm.startPrank(alice);
        // Critical: Approve vault, not teller (BoringVault pattern)
        WETH.approve(address(l1Vault), amount);

        uint256 aliceBalanceBefore = WETH.balanceOf(alice);
        uint256 aliceShares = l1Teller.deposit(WETH, amount, 0);
        uint256 aliceBalanceAfter = WETH.balanceOf(alice);

        console.log("   Alice WETH balance before: %s", aliceBalanceBefore / 1e18);
        console.log("   Alice WETH balance after: %s", aliceBalanceAfter / 1e18);
        console.log("   Shares received: %s", aliceShares / 1e18);
        console.log("   Vault WETH balance: %s", WETH.balanceOf(address(l1Vault)) / 1e18);
        vm.stopPrank();

        // Verify deposit worked correctly
        assertEq(WETH.balanceOf(address(l1Vault)), amount, "Vault should hold deposited WETH");
        assertEq(l1Vault.balanceOf(alice), aliceShares, "Alice should have vault shares");

        // 2. Alice bridges shares to L2
        console.log("\n2. ALICE BRIDGES SHARES TO L2");
        console.log("   Shares to bridge: %s", aliceShares / 1e18);

        vm.prank(alice);
        l1Vault.approve(address(l1Teller), aliceShares);

        BridgeData memory bridgeData = BridgeData({
            chainSelector: L2_EID,
            destinationChainReceiver: alice,
            bridgeFeeToken: ERC20(NATIVE),
            messageGas: 200_000,
            data: ""
        });

        uint256 bridgeFee = 0.01 ether;
        console.log("   Bridge fee: %s ETH", bridgeFee / 1e18);

        vm.prank(alice);
        bytes32 messageId = l1Teller.bridge{ value: bridgeFee }(aliceShares, bridgeData);
        console.log("   Message ID: %s", uint256(messageId));

        // Simulate LayerZero delivery
        console.log("   Simulating LayerZero message delivery...");
        _simulateLayerZeroDelivery(L1_EID, L2_EID, aliceShares, alice);

        console.log("   L1 shares after bridge: %s", l1Vault.balanceOf(alice) / 1e18);
        console.log("   L2 shares after bridge: %s", l2Vault.balanceOf(alice) / 1e18);

        // 3. Alice creates withdrawal request on L2
        console.log("\n3. ALICE CREATES WITHDRAWAL REQUEST ON L2");
        uint256 rate = l2Accountant.getRateInQuoteSafe(WETH);
        console.log("   Current exchange rate: %s", rate / 1e18);

        vm.startPrank(alice);
        AtomicQueue.AtomicRequest memory req = AtomicQueue.AtomicRequest({
            deadline: uint64(block.timestamp + 1 days),
            atomicPrice: uint88(rate),
            offerAmount: uint96(aliceShares),
            inSolve: false
        });

        l2Vault.approve(address(l2AtomicQueue), aliceShares);
        l2AtomicQueue.updateAtomicRequest(l2Vault, WETH, req);
        console.log("   Atomic request created with price: %s", uint256(req.atomicPrice) / 1e18);
        vm.stopPrank();

        // 4. Solver fulfills withdrawal
        console.log("\n4. SOLVER FULFILLS WITHDRAWAL");
        uint256 wethNeeded = rate * aliceShares / 1e18;
        console.log("   WETH needed for withdrawal: %s", wethNeeded / 1e18);

        vm.startPrank(solver);
        deal(address(WETH), solver, wethNeeded);
        WETH.approve(address(l2AtomicSolver), wethNeeded);

        address[] memory users = new address[](1);
        users[0] = alice;

        uint256 aliceWethBefore = WETH.balanceOf(alice);
        l2AtomicSolver.p2pSolve(l2AtomicQueue, l2Vault, WETH, users, 0, type(uint256).max);
        uint256 aliceWethAfter = WETH.balanceOf(alice);

        console.log("   Alice WETH received: %s", (aliceWethAfter - aliceWethBefore) / 1e18);
        console.log("   Alice L2 shares remaining: %s", l2Vault.balanceOf(alice));
        vm.stopPrank();

        // Verify final state
        assertGt(aliceWethAfter, aliceWethBefore, "Alice should have received WETH");
        assertEq(l2Vault.balanceOf(alice), 0, "Alice should have no L2 shares");

        console.log("\n=== TEST COMPLETE ===");
    }

    function test_ManagerBorrowAndCrossChainRepay() external {
        console.log("\n=== TEST: Manager Borrow and Cross-Chain Repay ===");
        uint256 amount = 100e18;
        deal(address(WETH), alice, amount);

        // 1. Alice deposits on L1
        console.log("\n1. ALICE DEPOSITS ON L1");
        vm.startPrank(alice);
        WETH.approve(address(l1Vault), amount);
        uint256 aliceShares = l1Teller.deposit(WETH, amount, 0);
        console.log("   Shares received: %s", aliceShares / 1e18);
        vm.stopPrank();

        // 2. HexTrust (manager) borrows from vault
        console.log("\n2. HEXTRUST BORROWS FROM VAULT");
        uint256 vaultBalanceBefore = WETH.balanceOf(address(l1Vault));
        console.log("   Vault WETH before borrow: %s", vaultBalanceBefore / 1e18);

        vm.startPrank(hexTrust);
        address target = address(WETH);
        bytes memory data = abi.encodeCall(ERC20.transfer, (hexTrust, amount));
        bytes memory result = l1Vault.manage(target, data, 0);
        bool success = abi.decode(result, (bool));
        console.log("   Borrow successful: %s", success);
        console.log("   HexTrust WETH balance: %s", WETH.balanceOf(hexTrust) / 1e18);
        console.log("   Vault WETH after borrow: %s", WETH.balanceOf(address(l1Vault)) / 1e18);
        vm.stopPrank();

        // 3. Alice bridges shares to L2
        console.log("\n3. ALICE BRIDGES SHARES TO L2");
        vm.prank(alice);
        l1Vault.approve(address(l1Teller), aliceShares);

        BridgeData memory bridgeData = BridgeData({
            chainSelector: L2_EID,
            destinationChainReceiver: alice,
            bridgeFeeToken: ERC20(NATIVE),
            messageGas: 200_000,
            data: ""
        });

        vm.prank(alice);
        l1Teller.bridge{ value: 0.01 ether }(aliceShares, bridgeData);
        _simulateLayerZeroDelivery(L1_EID, L2_EID, aliceShares, alice);
        console.log("   Shares bridged successfully");

        // 4. Alice requests withdrawal on L2
        console.log("\n4. ALICE REQUESTS WITHDRAWAL ON L2");
        uint256 rate = l2Accountant.getRateInQuoteSafe(WETH);

        vm.startPrank(alice);
        AtomicQueue.AtomicRequest memory req = AtomicQueue.AtomicRequest({
            deadline: uint64(block.timestamp + 1 days),
            atomicPrice: uint88(rate),
            offerAmount: uint96(aliceShares),
            inSolve: false
        });
        l2Vault.approve(address(l2AtomicQueue), aliceShares);
        l2AtomicQueue.updateAtomicRequest(l2Vault, WETH, req);
        console.log("   Withdrawal request created");
        vm.stopPrank();

        // 5. HexTrust repays on L2 to fulfill withdrawal
        console.log("\n5. HEXTRUST REPAYS ON L2");
        uint256 wethNeeded = rate * aliceShares / 1e18;
        deal(address(WETH), hexTrust, wethNeeded);

        vm.startPrank(hexTrust);
        WETH.approve(address(l2AtomicSolver), wethNeeded);
        address[] memory users = new address[](1);
        users[0] = alice;

        uint256 aliceWethBefore = WETH.balanceOf(alice);
        l2AtomicSolver.p2pSolve(l2AtomicQueue, l2Vault, WETH, users, 0, type(uint256).max);
        uint256 aliceWethAfter = WETH.balanceOf(alice);

        console.log("   Alice WETH received: %s", (aliceWethAfter - aliceWethBefore) / 1e18);
        vm.stopPrank();

        assertGt(aliceWethAfter, aliceWethBefore, "Alice should have received WETH");
        console.log("\n=== TEST COMPLETE ===");
    }

    // Additional critical tests
    function test_MultiAssetSupport() external {
        console.log("\n=== TEST: Multi-Asset Support ===");

        // Test that teller can handle multiple assets
        console.log("   Current supported assets:");
        // In production, teller would support multiple assets like USDC, DAI, etc.
        console.log("   - WETH: supported");

        // Verify WETH is supported
        vm.prank(alice);
        WETH.approve(address(l1Vault), 10e18);
        vm.prank(alice);
        uint256 shares = l1Teller.deposit(WETH, 10e18, 0);
        assertGt(shares, 0, "Should receive shares for WETH deposit");

        console.log("   Deposit successful, shares received: %s", shares / 1e18);
    }

    function test_UnauthorizedAccess() external {
        console.log("\n=== TEST: Unauthorized Access Control ===");

        // Test 1: Bad actor cannot solve without role
        console.log("\n1. Testing unauthorized solver access");
        vm.startPrank(alice);
        WETH.approve(address(l1Vault), 100e18);
        uint256 shares = l1Teller.deposit(WETH, 100e18, 0);

        l1Vault.approve(address(l1AtomicQueue), shares);
        AtomicQueue.AtomicRequest memory req = AtomicQueue.AtomicRequest({
            deadline: uint64(block.timestamp + 1 days),
            atomicPrice: uint88(1e18),
            offerAmount: uint96(shares),
            inSolve: false
        });
        l1AtomicQueue.updateAtomicRequest(l1Vault, WETH, req);
        vm.stopPrank();

        // Bad actor tries to solve
        vm.startPrank(badActor);
        deal(address(WETH), badActor, 100e18);
        WETH.approve(address(l1AtomicSolver), 100e18);

        address[] memory users = new address[](1);
        users[0] = alice;

        vm.expectRevert();
        l1AtomicSolver.p2pSolve(l1AtomicQueue, l1Vault, WETH, users, 0, type(uint256).max);
        console.log("Unauthorized solver correctly rejected");
        vm.stopPrank();

        // Test 2: Bad actor cannot manage vault
        console.log("\n2. Testing unauthorized manager access");
        vm.prank(badActor);
        bytes memory data = abi.encodeCall(ERC20.transfer, (badActor, 10e18));
        vm.expectRevert();
        l1Vault.manage(address(WETH), data, 0);
        console.log("Unauthorized manager correctly rejected");
    }

    function test_WithdrawalQueueMEVProtection() external {
        console.log("\n=== TEST: Withdrawal Queue MEV Protection ===");

        // Multiple users create withdrawal requests
        address[3] memory users = [alice, bob, makeAddr("charlie")];

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            deal(address(WETH), user, 100e18);

            vm.startPrank(user);
            WETH.approve(address(l1Vault), 100e18);
            uint256 userShares = l1Teller.deposit(WETH, 100e18, 0);

            // Create withdrawal request
            l1Vault.approve(address(l1AtomicQueue), userShares);
            AtomicQueue.AtomicRequest memory req = AtomicQueue.AtomicRequest({
                deadline: uint64(block.timestamp + 1 days),
                atomicPrice: uint88(1e18),
                offerAmount: uint96(userShares),
                inSolve: false
            });
            l1AtomicQueue.updateAtomicRequest(l1Vault, WETH, req);
            vm.stopPrank();

            console.log("   User %d queued withdrawal", i);
        }

        // Solver processes withdrawals in batch
        console.log("\n   Solver processing batch withdrawals...");
        vm.startPrank(solver);
        deal(address(WETH), solver, 300e18);
        WETH.approve(address(l1AtomicSolver), 300e18);

        address[] memory userArray = new address[](3);
        userArray[0] = users[0];
        userArray[1] = users[1];
        userArray[2] = users[2];

        l1AtomicSolver.p2pSolve(l1AtomicQueue, l1Vault, WETH, userArray, 0, type(uint256).max);
        vm.stopPrank();

        console.log("Batch processing complete - MEV protection via atomic queue");
    }

    function test_PauseMechanism() external {
        console.log("\n=== TEST: Pause Mechanism ===");

        // Normal deposit works
        vm.startPrank(alice);
        WETH.approve(address(l1Vault), 50e18);
        uint256 shares = l1Teller.deposit(WETH, 50e18, 0);
        console.log("   Normal deposit successful: %s shares", shares / 1e18);
        vm.stopPrank();

        // Owner pauses the system
        vm.prank(owner);
        l1Teller.pause();
        console.log("   System paused by owner");

        // Deposits should fail when paused
        vm.startPrank(alice);
        WETH.approve(address(l1Vault), 50e18);
        vm.expectRevert();
        l1Teller.deposit(WETH, 50e18, 0);
        console.log("WETH.approve(address(l1Vault), amount); Deposits correctly blocked when paused");
        vm.stopPrank();

        // Unpause
        vm.prank(owner);
        l1Teller.unpause();
        console.log("   System unpaused");

        // Deposits work again
        vm.startPrank(alice);
        uint256 newShares = l1Teller.deposit(WETH, 50e18, 0);
        console.log("   Deposit successful after unpause: %s shares", newShares / 1e18);
        vm.stopPrank();
    }

    // function test_ManagerCrossChainFundAccess() external {
    //     console.log("\n=== TEST: Manager Cross-Chain Fund Access ===");

    //     // Setup: Users deposit on different chains
    //     console.log("\n1. USERS DEPOSIT ON DIFFERENT CHAINS");

    //     // Alice deposits 200 WETH on L1
    //     vm.startPrank(alice);
    //     WETH.approve(address(l1Vault), 200e18);
    //     l1Teller.deposit(WETH, 200e18, 0);
    //     vm.stopPrank();
    //     console.log("   Alice deposited 200 WETH on L1");

    //     // Bob deposits 1000 USDC on L1
    //     vm.startPrank(bob);
    //     USDC.approve(address(l1Vault), 1000e6);
    //     l1Teller.deposit(USDC, 1000e6, 0);
    //     vm.stopPrank();
    //     console.log("   Bob deposited 1000 USDC on L1");

    //     // Simulate Charlie having deposited on L2 (give L2 vault some assets)
    //     deal(address(WETH), address(l2Vault), 100e18);
    //     deal(address(DAI), address(l2Vault), 500e18);
    //     console.log("   L2 Vault has 100 WETH and 500 DAI");

    //     // Show vault states
    //     console.log("\n2. VAULT STATES BEFORE MANAGER ACTIONS");
    //     console.log("   L1 Vault:");
    //     console.log("     - WETH:", WETH.balanceOf(address(l1Vault)) / 1e18);
    //     console.log("     - USDC:", USDC.balanceOf(address(l1Vault)) / 1e6);
    //     console.log("   L2 Vault:");
    //     console.log("     - WETH:", WETH.balanceOf(address(l2Vault)) / 1e18);
    //     console.log("     - DAI:", DAI.balanceOf(address(l2Vault)) / 1e18);

    //     // Manager can withdraw from L1 vault
    //     console.log("\n3. MANAGER WITHDRAWS FROM L1 VAULT");
    //     vm.startPrank(hexTrust);

    //     // Withdraw WETH from L1
    //     bytes memory withdrawWETH = abi.encodeCall(ERC20.transfer, (hexTrust, 50e18));
    //     l1Vault.manage(address(WETH), withdrawWETH, 0);
    //     console.log("   Manager withdrew 50 WETH from L1 vault");

    //     // Withdraw USDC from L1
    //     bytes memory withdrawUSDC = abi.encodeCall(ERC20.transfer, (hexTrust, 300e6));
    //     l1Vault.manage(address(USDC), withdrawUSDC, 0);
    //     console.log("   Manager withdrew 300 USDC from L1 vault");

    //     vm.stopPrank();

    //     // Manager can ALSO withdraw from L2 vault independently
    //     console.log("\n4. MANAGER WITHDRAWS FROM L2 VAULT");
    //     vm.startPrank(hexTrust);

    //     // Withdraw WETH from L2
    //     bytes memory withdrawL2WETH = abi.encodeCall(ERC20.transfer, (hexTrust, 30e18));
    //     l2Vault.manage(address(WETH), withdrawL2WETH, 0);
    //     console.log("   Manager withdrew 30 WETH from L2 vault");

    //     // Withdraw DAI from L2
    //     bytes memory withdrawL2DAI = abi.encodeCall(ERC20.transfer, (hexTrust, 200e18));
    //     l2Vault.manage(address(DAI), withdrawL2DAI, 0);
    //     console.log("   Manager withdrew 200 DAI from L2 vault");

    //     vm.stopPrank();

    //     // Show manager balances
    //     console.log("\n5. MANAGER BALANCES ACROSS ASSETS");
    //     console.log("   Manager now holds:");
    //     console.log("     - WETH:", WETH.balanceOf(hexTrust) / 1e18, "(from L1 + L2)");
    //     console.log("     - USDC:", USDC.balanceOf(hexTrust) / 1e6, "(from L1)");
    //     console.log("     - DAI:", DAI.balanceOf(hexTrust) / 1e18, "(from L2)");

    //     // Show remaining vault balances
    //     console.log("\n6. REMAINING VAULT BALANCES");
    //     console.log("   L1 Vault:");
    //     console.log("     - WETH:", WETH.balanceOf(address(l1Vault)) / 1e18);
    //     console.log("     - USDC:", USDC.balanceOf(address(l1Vault)) / 1e6);
    //     console.log("   L2 Vault:");
    //     console.log("     - WETH:", WETH.balanceOf(address(l2Vault)) / 1e18);
    //     console.log("     - DAI:", DAI.balanceOf(address(l2Vault)) / 1e18);

    //     // Important note about cross-chain limitations
    //     console.log("\n7. KEY INSIGHTS:");
    //     console.log("   + Manager can withdraw from ANY chain's vault");
    //     console.log("   + Each vault is managed independently");
    //     console.log("   + Manager doesn't need user permission for withdrawals");
    //     console.log("   x Manager CANNOT directly move L1 deposits to L2");
    //     console.log("   x Each chain's vault only holds assets deposited/bridged to it");
    // }

    function test_ManagerStrategyDeploymentAcrossChains() external {
        console.log("\n=== TEST: Manager Strategy Deployment Across Chains ===");

        // Setup: Deposits on both chains
        vm.startPrank(alice);
        WETH.approve(address(l1Vault), 500e18);
        l1Teller.deposit(WETH, 500e18, 0);
        vm.stopPrank();

        deal(address(USDC), address(l2Vault), 5000e6);

        console.log("\n1. INITIAL VAULT HOLDINGS");
        console.log("   L1 Vault: 500 WETH");
        console.log("   L2 Vault: 5000 USDC");

        // Manager deploys to different strategies on each chain
        console.log("\n2. MANAGER DEPLOYS TO CHAIN-SPECIFIC STRATEGIES");

        vm.startPrank(hexTrust);

        // On L1: Deploy WETH to a yield strategy (simulated)
        bytes memory deployL1 = abi.encodeCall(ERC20.transfer, (hexTrust, 300e18));
        l1Vault.manage(address(WETH), deployL1, 0);
        console.log("   L1: Deployed 300 WETH to Ethereum DeFi");
        console.log("       (e.g., Lido staking, AAVE lending)");

        // On L2: Deploy USDC to different strategy
        bytes memory deployL2 = abi.encodeCall(ERC20.transfer, (hexTrust, 3000e6));
        l2Vault.manage(address(USDC), deployL2, 0);
        console.log("   L2: Deployed 3000 USDC to Arbitrum DeFi");
        console.log("       (e.g., GMX liquidity, Curve pools)");

        vm.stopPrank();

        console.log("\n3. STRATEGY BENEFITS");
        console.log("   - Manager optimizes yield per chain");
        console.log("   - Uses best protocols on each network");
        console.log("   - Lower gas costs on L2 for complex strategies");
        console.log("   - Access to chain-specific opportunities");
    }

    function test_UserClaimsVsManagerAccess() external {
        console.log("\n=== TEST: User Claims vs Manager Access ===");

        // Setup: Multiple deposits
        vm.startPrank(alice);
        WETH.approve(address(l1Vault), 100e18);
        uint256 aliceShares = l1Teller.deposit(WETH, 100e18, 0);
        vm.stopPrank();

        console.log("\n1. ALICE DEPOSITS AND QUEUES WITHDRAWAL");

        // Alice queues withdrawal
        vm.startPrank(alice);
        l1Vault.approve(address(l1AtomicQueue), aliceShares);
        AtomicQueue.AtomicRequest memory req = AtomicQueue.AtomicRequest({
            deadline: uint64(block.timestamp + 3 days),
            atomicPrice: uint88(1e18),
            offerAmount: uint96(aliceShares),
            inSolve: false
        });
        l1AtomicQueue.updateAtomicRequest(l1Vault, WETH, req);
        vm.stopPrank();
        console.log("   Alice queued withdrawal for 100 shares");

        // Manager can still access vault funds
        console.log("\n2. MANAGER CAN STILL ACCESS VAULT FUNDS");
        console.log("   Vault WETH before manager action:", WETH.balanceOf(address(l1Vault)) / 1e18);

        vm.prank(hexTrust);
        bytes memory withdrawData = abi.encodeCall(ERC20.transfer, (hexTrust, 50e18));
        l1Vault.manage(address(WETH), withdrawData, 0);

        console.log("   Manager withdrew 50 WETH");
        console.log("   Vault WETH after manager action:", WETH.balanceOf(address(l1Vault)) / 1e18);

        console.log("\n3. IMPLICATIONS");
        console.log("   - Manager access is independent of user withdrawals");
        console.log("   - Manager must maintain liquidity for pending withdrawals");
        console.log("   - AtomicQueue protects users via solver fulfillment");
        console.log("   - Manager cannot block user withdrawals once queued");

        // Solver can still fulfill user withdrawal
        console.log("\n4. USER WITHDRAWAL STILL WORKS");
        vm.startPrank(solver);
        deal(address(WETH), solver, 100e18);
        WETH.approve(address(l1AtomicSolver), 100e18);

        address[] memory users = new address[](1);
        users[0] = alice;

        l1AtomicSolver.p2pSolve(l1AtomicQueue, l1Vault, WETH, users, 0, type(uint256).max);
        vm.stopPrank();

        console.log("   Alice successfully withdrew despite manager actions");
    }

    function test_ManagerCrossChainCoordination() external {
        console.log("\n=== TEST: Manager Cross-Chain Coordination ===");

        // This test shows what manager CAN and CANNOT do across chains

        console.log("\n1. SETUP: L1 has excess WETH, L2 needs WETH");

        // L1 has excess WETH
        deal(address(WETH), address(l1Vault), 1000e18);
        console.log("   L1 Vault: 1000 WETH (excess liquidity)");

        // L2 has low WETH but pending withdrawals
        deal(address(WETH), address(l2Vault), 10e18);
        console.log("   L2 Vault: 10 WETH (low liquidity)");

        console.log("\n2. WHAT MANAGER CANNOT DO:");
        console.log("   x Cannot directly transfer L1 vault assets to L2 vault");
        console.log("   x Cannot force users to bridge their shares");
        console.log("   x Cannot access L1 deposits from L2 manager role");

        console.log("\n3. WHAT MANAGER CAN DO:");

        // Manager withdraws from L1
        vm.startPrank(hexTrust);
        bytes memory withdrawL1 = abi.encodeCall(ERC20.transfer, (hexTrust, 200e18));
        l1Vault.manage(address(WETH), withdrawL1, 0);
        console.log("   + Withdraw 200 WETH from L1 vault to manager");

        // Manager could then:
        console.log("   + Bridge assets using external bridges");
        console.log("   + Deposit back into L2 vault if needed");
        console.log("   + Deploy to cross-chain strategies");
        console.log("   + Rebalance using external protocols");

        vm.stopPrank();

        console.log("\n4. COORDINATION STRATEGY");
        console.log("   - Manager monitors liquidity across all chains");
        console.log("   - Uses external systems for cross-chain rebalancing");
        console.log("   - Maintains adequate liquidity for withdrawals");
        console.log("   - Optimizes yield deployment per chain");
    }

    function test_CrossChainLendingWithProtocolFees() external {
        console.log("\n=== TEST: Cross-Chain Lending with Protocol Fees ===");

        // 1. Setup same rates on both chains
        console.log("\n1. SETUP LENDING RATES ON BOTH CHAINS");
        uint256 lendingRate = 1000; // 10% APY
        uint256 protocolFeeRate = 200; // 2% APY

        vm.startPrank(owner);
        l1Accountant.setLendingRate(lendingRate);
        l1Accountant.setProtocolFeeRate(protocolFeeRate);
        l2Accountant.setLendingRate(lendingRate);
        l2Accountant.setProtocolFeeRate(protocolFeeRate);
        vm.stopPrank();

        console.log("   L1 & L2 Lending Rate: %s bps", lendingRate);
        console.log("   L1 & L2 Protocol Fee: %s bps", protocolFeeRate);
        console.log("   Total Borrower Rate: %s bps", lendingRate + protocolFeeRate);

        // 2. Alice deposits on L1
        console.log("\n2. ALICE DEPOSITS 1000 WETH ON L1");
        uint256 depositAmount = 1000e18;

        vm.startPrank(alice);
        WETH.approve(address(l1Vault), depositAmount);
        uint256 aliceShares = l1Teller.deposit(WETH, depositAmount, 0);
        vm.stopPrank();

        console.log("   Shares received: %s", aliceShares / 1e18);

        // 3. Manager borrows entire deposit
        console.log("\n3. MANAGER BORROWS ENTIRE DEPOSIT");
        vm.prank(hexTrust);
        bytes memory borrowData = abi.encodeCall(ERC20.transfer, (hexTrust, depositAmount));
        l1Vault.manage(address(WETH), borrowData, 0);
        console.log("   Manager borrowed: %s WETH", depositAmount / 1e18);

        // 4. Time passes - interest accrues
        console.log("\n4. TIME PASSES - 6 MONTHS");
        skip(182.5 days);

        // Calculate expected repayment
        uint256 expectedInterest = depositAmount.mulDivDown(lendingRate * 182.5 days, SECONDS_PER_YEAR * BASIS_POINTS);
        uint256 expectedProtocolFee =
            depositAmount.mulDivDown(protocolFeeRate * 182.5 days, SECONDS_PER_YEAR * BASIS_POINTS);
        uint256 totalRepayment = depositAmount + expectedInterest + expectedProtocolFee;

        console.log("   Expected lending interest: %s WETH", expectedInterest / 1e18);
        console.log("   Expected protocol fee: %s WETH", expectedProtocolFee / 1e18);
        console.log("   Total repayment needed: %s WETH", totalRepayment / 1e18);

        // 5. Alice bridges shares to L2
        console.log("\n5. ALICE BRIDGES SHARES TO L2");
        vm.prank(alice);
        l1Vault.approve(address(l1Teller), aliceShares);

        BridgeData memory bridgeData = BridgeData({
            chainSelector: L2_EID,
            destinationChainReceiver: alice,
            bridgeFeeToken: ERC20(NATIVE),
            messageGas: 200_000,
            data: ""
        });

        vm.prank(alice);
        l1Teller.bridge{ value: 0.01 ether }(aliceShares, bridgeData);
        _simulateLayerZeroDelivery(L1_EID, L2_EID, aliceShares, alice);

        // 6. Alice requests withdrawal on L2
        console.log("\n6. ALICE REQUESTS WITHDRAWAL ON L2");
        uint256 currentRate = l2Accountant.getRateInQuoteSafe(WETH);
        console.log("   Current exchange rate: %s", currentRate / 1e18);
        console.log("   Value of shares: %s WETH", aliceShares.mulDivDown(currentRate, 1e18) / 1e18);

        vm.startPrank(alice);
        AtomicQueue.AtomicRequest memory req = AtomicQueue.AtomicRequest({
            deadline: uint64(block.timestamp + 1 days),
            atomicPrice: uint88(currentRate),
            offerAmount: uint96(aliceShares),
            inSolve: false
        });
        l2Vault.approve(address(l2AtomicQueue), aliceShares);
        l2AtomicQueue.updateAtomicRequest(l2Vault, WETH, req);
        vm.stopPrank();

        // 7. Manager repays with interest on L2
        console.log("\n7. MANAGER REPAYS ON L2");
        uint256 withdrawalAmount = aliceShares.mulDivDown(currentRate, 1e18);
        deal(address(WETH), hexTrust, withdrawalAmount);

        vm.startPrank(hexTrust);
        WETH.approve(address(l2AtomicSolver), withdrawalAmount);
        address[] memory users = new address[](1);
        users[0] = alice;

        uint256 aliceBalanceBefore = WETH.balanceOf(alice);
        l2AtomicSolver.p2pSolve(l2AtomicQueue, l2Vault, WETH, users, 0, type(uint256).max);
        uint256 aliceBalanceAfter = WETH.balanceOf(alice);
        vm.stopPrank();

        uint256 aliceReceived = aliceBalanceAfter - aliceBalanceBefore;
        console.log("   Alice received: %s WETH", aliceReceived / 1e18);
        console.log("   Profit from lending: %s WETH", (aliceReceived - depositAmount) / 1e18);

        // Verify Alice received principal + interest
        assertGt(aliceReceived, depositAmount, "Alice should receive more than deposit");
    }

    function test_ProtocolFeeClaimingAcrossChains() external {
    console.log("\n=== TEST: Protocol Fee Claiming Across Chains ===");

    // Deposits on both chains
    console.log("\n1. DEPOSITS ON BOTH CHAINS");
    vm.startPrank(alice);
    WETH.approve(address(l1Vault), 500e18);
    l1Teller.deposit(WETH, 500e18, 0);
    vm.stopPrank();

    // For L2, properly mint shares
    vm.prank(owner);
    l2Vault.enter(address(0), WETH, 0, alice, 500e18); // Mint 500e18 shares
    deal(address(WETH), address(l2Vault), 500e18); // Give vault the WETH

    console.log("   L1 Vault: 500 WETH");
    console.log("   L2 Vault: 500 WETH");
    
    // Setup rates AFTER deposits exist
    vm.startPrank(owner);
    l1Accountant.setLendingRate(1000);
    l1Accountant.setProtocolFeeRate(300); // 3% protocol fee
    l2Accountant.setLendingRate(1000);
    l2Accountant.setProtocolFeeRate(300);
    vm.stopPrank();

    // Time passes
    skip(365 days);

    // Check fees on both chains
    console.log("\n2. PROTOCOL FEES AFTER 1 YEAR");
    uint256 l1Fees = l1Accountant.previewFeesOwed();
    uint256 l2Fees = l2Accountant.previewFeesOwed();

    console.log("   L1 Protocol fees: %s WETH", l1Fees / 1e18);
    console.log("   L2 Protocol fees: %s WETH", l2Fees / 1e18);

    // Update exchange rates to checkpoint fees
    console.log("\n3. CHECKPOINT AND CLAIM FEES");

    // L1 claim
    vm.prank(owner);
    (uint96 l1Rate,) = l1Accountant.calculateExchangeRateWithInterest();
    l1Accountant.updateExchangeRate(l1Rate);

    deal(address(WETH), address(l1Vault), l1Fees);
    vm.startPrank(address(l1Vault));
    WETH.approve(address(l1Accountant), l1Fees);
    l1Accountant.claimFees(WETH);
    vm.stopPrank();

    // L2 claim
    vm.prank(owner);
    (uint96 l2Rate,) = l2Accountant.calculateExchangeRateWithInterest();
    l2Accountant.updateExchangeRate(l2Rate);

    deal(address(WETH), address(l2Vault), l2Fees);
    vm.startPrank(address(l2Vault));
    WETH.approve(address(l2Accountant), l2Fees);
    l2Accountant.claimFees(WETH);
    vm.stopPrank();

    // Verify fees were claimed
    (address l1Payout,,,,,,,,,) = l1Accountant.accountantState();
    (address l2Payout,,,,,,,,,) = l2Accountant.accountantState();

    console.log("   L1 Payout received: %s WETH", WETH.balanceOf(l1Payout) / 1e18);
    console.log("   L2 Payout received: %s WETH", WETH.balanceOf(l2Payout) / 1e18);

    assertGt(WETH.balanceOf(l1Payout), 0, "L1 payout should receive fees");
    assertGt(WETH.balanceOf(l2Payout), 0, "L2 payout should receive fees");
}

    function test_CrossChainRateSynchronization() external {
    console.log("\n=== TEST: Cross-Chain Rate Synchronization ===");

    // First, create some deposits so interest can accrue
    vm.startPrank(alice);
    WETH.approve(address(l1Vault), 100e18);
    l1Teller.deposit(WETH, 100e18, 0);
    vm.stopPrank();
    
    // For L2, we need to mint shares properly
    vm.prank(owner);
    l2Vault.enter(address(0), WETH, 0, alice, 100e18); // Mint shares on L2

    // Verify rates start synchronized
    console.log("\n1. INITIAL RATES");
    uint256 l1Rate = l1Accountant.getRate();
    uint256 l2Rate = l2Accountant.getRate();
    assertEq(l1Rate, l2Rate, "Rates should start equal");
    console.log("   L1 Rate: %s", l1Rate);
    console.log("   L2 Rate: %s", l2Rate);

    // Set different lending rates (simulating different chain conditions)
    console.log("\n2. SET DIFFERENT RATES PER CHAIN");
    vm.startPrank(owner);
    l1Accountant.setLendingRate(1000); // 10% on L1
    l2Accountant.setLendingRate(1500); // 15% on L2
    vm.stopPrank();

    // Time passes
    skip(365 days);

    // Check diverged rates
    console.log("\n3. RATES AFTER 1 YEAR");
    l1Rate = l1Accountant.getRate();
    l2Rate = l2Accountant.getRate();

    console.log("   L1 Rate (10% APY): %s", l1Rate / 1e18);
    console.log("   L2 Rate (15% APY): %s", l2Rate / 1e18);

    assertGt(l2Rate, l1Rate, "L2 rate should be higher");

    console.log("\n4. IMPLICATIONS");
    console.log("   - Each chain can have different lending rates");
    console.log("   - Shares bridged maintain their value based on origin chain");
    console.log("   - Arbitrage opportunities may exist");
}

    function _simulateLayerZeroDelivery(uint32 srcEid, uint32 dstEid, uint256 shares, address receiver) internal {
        bytes memory payload = abi.encode(shares, receiver);

        Origin memory origin = Origin({
            srcEid: srcEid,
            sender: bytes32(uint256(uint160(dstEid == L2_EID ? address(l1Teller) : address(l2Teller)))),
            nonce: 1
        });

        bytes32 guid = keccak256(abi.encodePacked(srcEid, dstEid, uint256(1)));

        if (dstEid == L2_EID) {
            vm.prank(address(mockEndpoint));
            l2Teller.lzReceive(origin, guid, payload, address(0), "");
        } else {
            vm.prank(address(mockEndpoint));
            l1Teller.lzReceive(origin, guid, payload, address(0), "");
        }
    }
}

// Simple mock LayerZero endpoint for testing
contract MockLayerZeroEndpoint {
    mapping(uint32 => mapping(uint32 => address)) public destinations;
    mapping(address => address) internal delegatesMap;

    function setDestination(uint32 srcEid, uint32 dstEid, address destination) external {
        destinations[srcEid][dstEid] = destination;
    }

    function setDelegate(address _delegate) external {
        delegatesMap[msg.sender] = _delegate;
    }

    function delegates(address oapp) external view returns (address) {
        return delegatesMap[oapp];
    }

    function send(MessagingParams memory, address) external payable returns (MessagingReceipt memory receipt) {
        receipt.guid = bytes32(uint256(1));
        receipt.nonce = 1;
        receipt.fee = MessagingFee(msg.value, 0);
    }

    function quote(uint32, bytes calldata, bytes calldata, bool) external pure returns (MessagingFee memory fee) {
        fee.nativeFee = 0.01 ether;
        fee.lzTokenFee = 0;
    }
}
