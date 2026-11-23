// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only token exercising failure and callback paths. Never deployed by the launch.
contract AdversarialToken is ERC20 {
    enum Mode {
        Normal,
        ReturnFalse,
        Revert,
        NoReturn,
        NoMovement,
        TransferFee
    }

    Mode public incomingMode;
    Mode public outgoingMode;
    address public callbackTarget;
    bytes public callbackData;
    bool public bubbleCallback;
    bool public callbackSucceeded;
    bytes public callbackResult;
    uint256 public callbackCount;

    error TokenRefused();

    constructor(address recipient, uint256 amount) ERC20("Adversarial test fixture", "MOCK") {
        _mint(recipient, amount);
    }

    function setModes(Mode incoming, Mode outgoing) external {
        incomingMode = incoming;
        outgoingMode = outgoing;
    }

    function setCallback(address target, bytes calldata data, bool bubble) external {
        callbackTarget = target;
        callbackData = data;
        bubbleCallback = bubble;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        Mode mode = outgoingMode;
        if (mode == Mode.ReturnFalse) return false;
        if (mode == Mode.Revert) revert TokenRefused();
        if (mode == Mode.NoMovement) return true;
        super.transfer(to, amount);
        _callback();
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        Mode mode = incomingMode;
        if (mode == Mode.ReturnFalse) return false;
        if (mode == Mode.Revert) revert TokenRefused();
        if (mode == Mode.NoMovement) return true;
        super.transferFrom(from, to, amount);
        if (mode == Mode.TransferFee) _burn(to, 1);
        _callback();
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function _callback() private {
        if (callbackTarget == address(0)) return;
        ++callbackCount;
        (bool success, bytes memory result) = callbackTarget.call(callbackData);
        callbackSucceeded = success;
        callbackResult = result;
        if (!success && bubbleCallback) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }
}
