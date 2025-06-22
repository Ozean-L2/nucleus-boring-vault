// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { Test, stdStorage, StdStorage, stdError, console } from "@forge-std/Test.sol";
import { DeployPortLayerZeroScript } from "../../script/DeployPortLayerZero.s.sol";
import { SafeTransferLib } from "@solmate/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { ERC20 } from "@solmate/tokens/ERC20.sol";
import { AtomicQueue } from "src/atomic-queue/AtomicQueue.sol";
import { BridgeData } from "src/base/Roles/CrossChain/CrossChainTellerBase.sol";
import { Origin, MessagingFee, MessagingReceipt } from "src/base/Roles/CrossChain/OAppAuth/OAppAuth.sol";

// Import LayerZero interfaces to get the correct struct definitions
import {
    ILayerZeroEndpointV2,
    MessagingParams
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @dev forge test --match-contract PortLayerZeroPoCTest
contract PortLayerZeroPoCTest is Test, DeployPortLayerZeroScript {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    address public alice = makeAddr("alice");
    address public solver = makeAddr("solver");

    // Mock LayerZero endpoint for testing
    MockLayerZeroEndpoint public mockEndpoint;

    function setUp() external {
        uint256 forkId = vm.createFork(vm.envString("MAINNET_RPC_URL"));
        vm.selectFork(forkId);

        // Setup mock LayerZero endpoint
        mockEndpoint = new MockLayerZeroEndpoint();

        // Set test addresses
        hexTrust = makeAddr("hexTrust");

        // Run deployment with mock endpoint
        run(address(this), hexTrust, address(mockEndpoint));

        // Setup mock endpoint connections
        mockEndpoint.setDestination(L1_EID, L2_EID, address(l2Teller));
        mockEndpoint.setDestination(L2_EID, L1_EID, address(l1Teller));

        // Fund test accounts
        deal(address(WETH), alice, 1000e18);
        deal(address(WETH), solver, 1000e18);
        deal(address(WETH), hexTrust, 1000e18);
        deal(alice, 10 ether);
        deal(solver, 10 ether);
        deal(hexTrust, 10 ether);

        // Give solver the CAN_SOLVE_ROLE on both chains
        vm.prank(owner);
        l1Authority.setUserRole(solver, CAN_SOLVE_ROLE, true);
        vm.prank(owner);
        l2Authority.setUserRole(solver, CAN_SOLVE_ROLE, true);
    }

    function test_CrossChainDepositAndWithdraw() external {
        uint256 amount = 100e18;

        // 1. Alice deposits WETH on L1
        vm.startPrank(alice);
        WETH.approve(address(l1Vault), amount);
        uint256 aliceShares = l1Teller.deposit(WETH, amount, 0);
        vm.stopPrank();

        // Verify L1 state - shares might not be 1:1 with amount due to exchange rate
        assertEq(WETH.balanceOf(address(l1Vault)), amount);
        assertEq(l1Vault.balanceOf(alice), aliceShares);
        assertGt(aliceShares, 0, "Should have received some shares");

        // 2. Alice bridges shares to L2
        vm.prank(alice);
        l1Vault.approve(address(l1Teller), aliceShares);

        // Prepare bridge data
        BridgeData memory bridgeData = BridgeData({
            chainSelector: L2_EID,
            destinationChainReceiver: alice,
            bridgeFeeToken: ERC20(NATIVE), // native token
            messageGas: 200_000,
            data: ""
        });

        // Get bridge fee quote (mock returns 0.01 ETH)
        uint256 bridgeFee = 0.01 ether;

        // Bridge shares to L2
        vm.prank(alice);
        bytes32 messageId = l1Teller.bridge{ value: bridgeFee }(aliceShares, bridgeData);

        // Mock LayerZero message delivery
        _simulateLayerZeroDelivery(L1_EID, L2_EID, aliceShares, alice);

        // Verify state after bridge
        assertEq(l1Vault.balanceOf(alice), 0); // Shares burned on L1
        assertEq(l2Vault.balanceOf(alice), aliceShares); // Shares minted on L2

        // 3. Alice creates withdrawal request on L2
        // Get the exchange rate first
        uint256 rate = l2Accountant.getRateInQuoteSafe(WETH);

        vm.startPrank(alice);
        // Set atomic price to match the exchange rate so Alice gets back her original deposit
        AtomicQueue.AtomicRequest memory req = AtomicQueue.AtomicRequest({
            deadline: uint64(block.timestamp + 1 days),
            atomicPrice: uint88(rate),
            offerAmount: uint96(aliceShares),
            inSolve: false
        });
        l2Vault.approve(address(l2AtomicQueue), aliceShares);
        l2AtomicQueue.updateAtomicRequest(l2Vault, WETH, req);
        vm.stopPrank();

        // 4. Solver fulfills withdrawal on L2
        vm.startPrank(solver);
        // Calculate how much WETH is needed based on the current rate
        uint256 wethNeeded = l2Accountant.getRateInQuoteSafe(WETH) * aliceShares / 1e18;
        deal(address(WETH), solver, wethNeeded);
        WETH.approve(address(l2AtomicSolver), wethNeeded);
        address[] memory users = new address[](1);
        users[0] = alice;
        l2AtomicSolver.p2pSolve(l2AtomicQueue, l2Vault, WETH, users, 0, type(uint256).max);
        vm.stopPrank();

        // Verify final state
        assertGt(WETH.balanceOf(alice), 0, "Alice should have received WETH");
        assertEq(l2Vault.balanceOf(alice), 0);
    }

    function test_ManagerBorrowAndCrossChainRepay() external {
        uint256 amount = 100e18;
        deal(address(WETH), alice, amount);

        // 1. Alice deposits on L1
        vm.startPrank(alice);
        WETH.approve(address(l1Vault), amount);
        uint256 aliceShares = l1Teller.deposit(WETH, amount, 0);
        vm.stopPrank();

        // 2. HexTrust borrows from L1 vault
        vm.startPrank(hexTrust);
        address target = address(WETH);
        bytes memory data = abi.encodeCall(ERC20.transfer, (hexTrust, amount));
        l1Vault.manage(target, data, 0);
        vm.stopPrank();

        // 3. Alice bridges shares to L2 for withdrawal
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

        // 4. Alice requests withdrawal on L2
        // Get the exchange rate first
        uint256 rate = l2Accountant.getRateInQuoteSafe(WETH);

        vm.startPrank(alice);
        // Set atomic price to match the exchange rate
        AtomicQueue.AtomicRequest memory req = AtomicQueue.AtomicRequest({
            deadline: uint64(block.timestamp + 1 days),
            atomicPrice: uint88(rate), // Use actual exchange rate
            offerAmount: uint96(aliceShares),
            inSolve: false
        });
        l2Vault.approve(address(l2AtomicQueue), aliceShares);
        l2AtomicQueue.updateAtomicRequest(l2Vault, WETH, req);
        vm.stopPrank();

        // 5. HexTrust repays on L2 to fulfill withdrawal
        uint256 wethNeeded = l2Accountant.getRateInQuoteSafe(WETH) * aliceShares / 1e18;
        deal(address(WETH), hexTrust, wethNeeded);
        vm.startPrank(hexTrust);
        WETH.approve(address(l2AtomicSolver), wethNeeded);
        address[] memory users = new address[](1);
        users[0] = alice;
        l2AtomicSolver.p2pSolve(l2AtomicQueue, l2Vault, WETH, users, 0, type(uint256).max);
        vm.stopPrank();

        // Verify final state
        assertGt(WETH.balanceOf(alice), 0, "Alice should have received WETH");
        assertEq(l1Vault.balanceOf(alice), 0);
        assertEq(l2Vault.balanceOf(alice), 0);
    }

    function _simulateLayerZeroDelivery(uint32 srcEid, uint32 dstEid, uint256 shares, address receiver) internal {
        bytes memory payload = abi.encode(shares, receiver);

        // Create Origin struct for LayerZero
        Origin memory origin = Origin({
            srcEid: srcEid,
            sender: bytes32(uint256(uint160(dstEid == L2_EID ? address(l1Teller) : address(l2Teller)))),
            nonce: 1
        });

        bytes32 guid = keccak256(abi.encodePacked(srcEid, dstEid, uint256(1)));

        if (dstEid == L2_EID) {
            vm.prank(address(mockEndpoint));
            l2Teller.lzReceive(
                origin,
                guid,
                payload,
                address(0), // executor
                "" // extra data
            );
        } else {
            vm.prank(address(mockEndpoint));
            l1Teller.lzReceive(
                origin,
                guid,
                payload,
                address(0), // executor
                "" // extra data
            );
        }
    }
}

// Simple mock LayerZero endpoint for testing
contract MockLayerZeroEndpoint {
    mapping(uint32 => mapping(uint32 => address)) public destinations;
    address public delegate;

    function setDestination(uint32 srcEid, uint32 dstEid, address destination) external {
        destinations[srcEid][dstEid] = destination;
    }

    function setDelegate(address _delegate) external {
        delegate = _delegate;
    }

    // V2 send function that the teller will call
    function send(MessagingParams memory, address) external payable returns (MessagingReceipt memory receipt) {
        receipt.guid = bytes32(uint256(1));
        receipt.nonce = 1;
        receipt.fee = MessagingFee(msg.value, 0);
    }

    // Quote function for fee estimation
    function quote(uint32, bytes calldata, bytes calldata, bool) external pure returns (MessagingFee memory fee) {
        fee.nativeFee = 0.01 ether;
        fee.lzTokenFee = 0;
    }
}
