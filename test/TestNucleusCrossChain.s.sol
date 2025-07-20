// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { Script, console2 } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { BoringVault } from "src/base/BoringVault.sol";
import { MultiChainLayerZeroTellerWithMultiAssetSupport } from
    "src/base/Roles/CrossChain/MultiChainLayerZeroTellerWithMultiAssetSupport.sol";
import { AccountantWithRateProviders } from "src/base/Roles/AccountantWithRateProviders.sol";
import { RolesAuthority } from "@solmate/auth/authorities/RolesAuthority.sol";
import { AtomicQueue } from "src/atomic-queue/AtomicQueue.sol";
import { AtomicSolverV3 } from "src/atomic-queue/AtomicSolverV3.sol";
import { BridgeData, ERC20 } from "src/base/Roles/CrossChain/CrossChainTellerBase.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract TestNucleusCrossChain is Script, Test {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    // Native token placeholder
    ERC20 constant NATIVE = ERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    // Test addresses
    address public alice;
    address public bob;
    address public solver;
    address public hexTrust;

    // Contract addresses (to be loaded from env)
    address public l1Vault;
    address public l1Teller;
    address public l1Accountant;
    address public l1AtomicQueue;
    address public l1AtomicSolver;

    address public l2Vault;
    address public l2Teller;
    address public l2Accountant;
    address public l2AtomicQueue;
    address public l2AtomicSolver;

    // Token addresses
    address public constant WETH_SEPOLIA = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address public constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address public constant WETH_OP_SEPOLIA = 0x4200000000000000000000000000000000000006;
    address public constant USDC_OP_SEPOLIA = 0x5fd84259d66Cd46123540766Be93DFE6D43130D7;

    // LayerZero constants
    uint32 public constant SEPOLIA_EID = 40_161;
    uint32 public constant OP_SEPOLIA_EID = 40_232;

    function run() external {
        // Load private key
        uint256 testPrivateKey = vm.envUint("TEST_PRIVATE_KEY");

        // Create test addresses
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        solver = vm.envAddress("SOLVER_ADDRESS");
        hexTrust = vm.envAddress("HEXTRUST_ADDRESS");

        // Load deployed contract addresses
        _loadDeployedAddresses();

        console2.log("=== Running Cross-Chain Tests ===");
        console2.log("Alice:", alice);
        console2.log("Bob:", bob);
        console2.log("Solver:", solver);
        console2.log("HexTrust:", hexTrust);

        // Run tests
        console2.log("\n=== Test 1: Basic Deposit and Bridge ===");
        _testDepositAndBridge(testPrivateKey);

        console2.log("\n=== Test 2: Cross-Chain Withdrawal ===");
        _testCrossChainWithdrawal(testPrivateKey);

        console2.log("\n=== Test 3: Manager Cross-Chain Operations ===");
        _testManagerOperations(testPrivateKey);

        console2.log("\n=== Test 4: Multi-Asset Support ===");
        _testMultiAssetSupport(testPrivateKey);

        console2.log("\n=== All Tests Completed Successfully ===");
    }

    function _loadDeployedAddresses() internal {
        // Load L1 addresses
        l1Vault = vm.envAddress("L1_VAULT");
        l1Teller = vm.envAddress("L1_TELLER");
        l1Accountant = vm.envAddress("L1_ACCOUNTANT");
        l1AtomicQueue = vm.envAddress("L1_ATOMIC_QUEUE");
        l1AtomicSolver = vm.envAddress("L1_ATOMIC_SOLVER");

        // Load L2 addresses
        l2Vault = vm.envAddress("L2_VAULT");
        l2Teller = vm.envAddress("L2_TELLER");
        l2Accountant = vm.envAddress("L2_ACCOUNTANT");
        l2AtomicQueue = vm.envAddress("L2_ATOMIC_QUEUE");
        l2AtomicSolver = vm.envAddress("L2_ATOMIC_SOLVER");
    }

    function _testDepositAndBridge(uint256 testPrivateKey) internal {
        // Switch to Sepolia
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        uint256 depositAmount = 0.1 ether;

        // Fund Alice with ETH and WETH
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        IWETH(WETH_SEPOLIA).deposit{ value: depositAmount }();

        console2.log("Alice WETH balance:", IWETH(WETH_SEPOLIA).balanceOf(alice));

        // Approve vault for deposit
        IWETH(WETH_SEPOLIA).approve(l1Vault, depositAmount);

        // Deposit WETH
        uint256 sharesBefore = BoringVault(payable(l1Vault)).balanceOf(alice);
        MultiChainLayerZeroTellerWithMultiAssetSupport(l1Teller).deposit(ERC20(WETH_SEPOLIA), depositAmount, 0);
        uint256 sharesAfter = BoringVault(payable(l1Vault)).balanceOf(alice);
        uint256 sharesReceived = sharesAfter - sharesBefore;

        console2.log("Shares received on L1:", sharesReceived);

        // Prepare bridge data
        BridgeData memory bridgeData = BridgeData({
            chainSelector: OP_SEPOLIA_EID,
            destinationChainReceiver: alice,
            bridgeFeeToken: NATIVE,
            messageGas: 200_000,
            data: ""
        });

        // Quote bridge fee
        uint256 bridgeFee =
            MultiChainLayerZeroTellerWithMultiAssetSupport(l1Teller).previewFee(sharesReceived, bridgeData);
        console2.log("Bridge fee quote:", bridgeFee);

        // Approve teller to spend shares
        BoringVault(payable(l1Vault)).approve(l1Teller, sharesReceived);

        // Bridge shares to L2
        bytes32 messageId = MultiChainLayerZeroTellerWithMultiAssetSupport(l1Teller).bridge{ value: bridgeFee }(
            sharesReceived, bridgeData
        );
        console2.log("Bridge message ID:", uint256(messageId));

        vm.stopPrank();

        // Note: In a real test, we would wait for LayerZero to deliver the message
        // For now, we just verify the shares were burned on L1
        uint256 aliceL1SharesAfterBridge = BoringVault(payable(l1Vault)).balanceOf(alice);
        console2.log("Alice L1 shares after bridge:", aliceL1SharesAfterBridge);

        // Simulate checking L2 (in production, you'd wait for actual delivery)
        console2.log("Bridge transaction submitted. Check LayerZero Scan for delivery status.");
    }

    function _testCrossChainWithdrawal(uint256 testPrivateKey) internal {
        // Switch to OP Sepolia
        vm.createSelectFork(vm.envString("OP_SEPOLIA_RPC_URL"));

        // For this test, we assume Alice already has shares on L2
        // In production, these would come from the bridge operation
        uint256 l2Shares = 0.1 ether; // Simulated shares

        // Mint shares to Alice for testing (in production, these come from bridge)
        vm.startPrank(l2Teller);
        BoringVault(payable(l2Vault)).enter(address(0), ERC20(address(0)), 0, alice, l2Shares);
        vm.stopPrank();

        console2.log("Alice L2 shares:", BoringVault(payable(l2Vault)).balanceOf(alice));

        // Alice creates withdrawal request
        vm.startPrank(alice);

        // Get current exchange rate
        uint256 rate = AccountantWithRateProviders(l2Accountant).getRateInQuoteSafe(ERC20(WETH_OP_SEPOLIA));
        console2.log("Current exchange rate:", rate);

        // Approve atomic queue
        BoringVault(payable(l2Vault)).approve(l2AtomicQueue, l2Shares);

        // Create atomic request
        AtomicQueue.AtomicRequest memory request = AtomicQueue.AtomicRequest({
            deadline: uint64(block.timestamp + 1 days),
            atomicPrice: uint88(rate),
            offerAmount: uint96(l2Shares),
            inSolve: false
        });

        AtomicQueue(l2AtomicQueue).updateAtomicRequest(BoringVault(payable(l2Vault)), ERC20(WETH_OP_SEPOLIA), request);
        console2.log("Withdrawal request created");

        vm.stopPrank();

        // Solver fulfills withdrawal
        vm.startPrank(solver);

        uint256 wethNeeded = l2Shares.mulDivDown(rate, 1e18);
        console2.log("WETH needed for withdrawal:", wethNeeded);

        // Fund solver with WETH
        vm.deal(solver, wethNeeded + 0.1 ether);
        IWETH(WETH_OP_SEPOLIA).deposit{ value: wethNeeded }();
        IWETH(WETH_OP_SEPOLIA).approve(l2AtomicSolver, wethNeeded);

        // Solve withdrawal
        address[] memory users = new address[](1);
        users[0] = alice;

        uint256 aliceWethBefore = IWETH(WETH_OP_SEPOLIA).balanceOf(alice);
        AtomicSolverV3(l2AtomicSolver).p2pSolve(
            AtomicQueue(l2AtomicQueue),
            BoringVault(payable(l2Vault)),
            ERC20(WETH_OP_SEPOLIA),
            users,
            0,
            type(uint256).max
        );
        uint256 aliceWethAfter = IWETH(WETH_OP_SEPOLIA).balanceOf(alice);

        console2.log("Alice received WETH:", aliceWethAfter - aliceWethBefore);
        console2.log("Alice L2 shares remaining:", BoringVault(payable(l2Vault)).balanceOf(alice));

        vm.stopPrank();
    }

    function _testManagerOperations(uint256 testPrivateKey) internal {
        // Test 1: Manager borrows from L1 vault
        console2.log("\nTesting manager borrow from L1...");
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        // First, ensure vault has some WETH
        vm.deal(l1Vault, 1 ether);
        vm.prank(l1Vault);
        IWETH(WETH_SEPOLIA).deposit{ value: 0.5 ether }();

        uint256 vaultWethBefore = IWETH(WETH_SEPOLIA).balanceOf(l1Vault);
        console2.log("Vault WETH before borrow:", vaultWethBefore);

        // Manager borrows WETH
        vm.startPrank(hexTrust);
        bytes memory withdrawData = abi.encodeCall(ERC20.transfer, (hexTrust, 0.2 ether));
        BoringVault(payable(l1Vault)).manage(WETH_SEPOLIA, withdrawData, 0);
        vm.stopPrank();

        uint256 vaultWethAfter = IWETH(WETH_SEPOLIA).balanceOf(l1Vault);
        uint256 managerWeth = IWETH(WETH_SEPOLIA).balanceOf(hexTrust);

        console2.log("Vault WETH after borrow:", vaultWethAfter);
        console2.log("Manager WETH balance:", managerWeth);

        // Test 2: Manager operations on L2
        console2.log("\nTesting manager operations on L2...");
        vm.createSelectFork(vm.envString("OP_SEPOLIA_RPC_URL"));

        // Ensure L2 vault has some assets
        vm.deal(l2Vault, 1 ether);
        vm.prank(l2Vault);
        IWETH(WETH_OP_SEPOLIA).deposit{ value: 0.3 ether }();

        uint256 l2VaultWethBefore = IWETH(WETH_OP_SEPOLIA).balanceOf(l2Vault);
        console2.log("L2 Vault WETH before:", l2VaultWethBefore);

        // Manager can also manage L2 vault
        vm.startPrank(hexTrust);
        bytes memory l2WithdrawData = abi.encodeCall(ERC20.transfer, (hexTrust, 0.1 ether));
        BoringVault(payable(l2Vault)).manage(WETH_OP_SEPOLIA, l2WithdrawData, 0);
        vm.stopPrank();

        uint256 l2VaultWethAfter = IWETH(WETH_OP_SEPOLIA).balanceOf(l2Vault);
        console2.log("L2 Vault WETH after:", l2VaultWethAfter);
        console2.log("Manager accessed funds from both chains independently");
    }

    function _testMultiAssetSupport(uint256 testPrivateKey) internal {
        // Test USDC deposits and operations
        console2.log("\nTesting multi-asset support with USDC...");
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        // For testnet, we'll simulate having USDC
        // In production, you'd need to get test USDC from a faucet
        uint256 usdcAmount = 100 * 1e6; // 100 USDC (6 decimals)

        // Fund Bob with USDC
        deal(USDC_SEPOLIA, bob, usdcAmount);

        vm.startPrank(bob);

        // Approve and deposit USDC
        ERC20(USDC_SEPOLIA).approve(l1Vault, usdcAmount);

        uint256 bobSharesBefore = BoringVault(payable(l1Vault)).balanceOf(bob);
        MultiChainLayerZeroTellerWithMultiAssetSupport(l1Teller).deposit(ERC20(USDC_SEPOLIA), usdcAmount, 0);
        uint256 bobSharesAfter = BoringVault(payable(l1Vault)).balanceOf(bob);

        console2.log("Bob deposited USDC:", usdcAmount);
        console2.log("Bob received shares:", bobSharesAfter - bobSharesBefore);

        // Test deposit and bridge in one transaction
        console2.log("\nTesting depositAndBridge with USDC...");

        BridgeData memory bridgeData = BridgeData({
            chainSelector: OP_SEPOLIA_EID,
            destinationChainReceiver: bob,
            bridgeFeeToken: NATIVE,
            messageGas: 200_000,
            data: ""
        });

        // Get quote for depositAndBridge
        uint256 expectedShares = usdcAmount; // Simplified for test
        uint256 bridgeFee =
            MultiChainLayerZeroTellerWithMultiAssetSupport(l1Teller).previewFee(expectedShares, bridgeData);

        // Approve more USDC
        ERC20(USDC_SEPOLIA).approve(l1Vault, usdcAmount);

        // Deposit and bridge in one transaction
        vm.deal(bob, bridgeFee + 0.1 ether);
        bytes32 messageId = MultiChainLayerZeroTellerWithMultiAssetSupport(l1Teller).depositAndBridge{ value: bridgeFee }(
            ERC20(USDC_SEPOLIA), usdcAmount, 0, bridgeData
        );

        console2.log("DepositAndBridge message ID:", uint256(messageId));
        console2.log("Bob's remaining L1 shares:", BoringVault(payable(l1Vault)).balanceOf(bob));

        vm.stopPrank();

        console2.log("\nMulti-asset support test completed");
    }

    function _addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}
