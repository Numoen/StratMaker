// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.17;

import {Engine} from "src/core/Engine.sol";
import {Positions} from "src/core/Positions.sol";
import {IExecuteCallback} from "src/core/interfaces/IExecuteCallback.sol";
import {ILRTA} from "ilrta/ILRTA.sol";
import {Permit3} from "ilrta/Permit3.sol";
import {SuperSignature} from "ilrta/SuperSignature.sol";

/// @author Robert Leifke and Kyle Scott
/// @custom:team route by signature
contract Router is IExecuteCallback {
    Engine private immutable engine;
    Permit3 private immutable permit3;
    SuperSignature private immutable superSignature;

    error InvalidCaller(address caller);

    struct CallbackData {
        Permit3.TransferDetails[] permitTransfers;
        Positions.ILRTATransferDetails[] positionTransfers;
        bytes32[] dataHash;
        address payer;
    }

    constructor(address _engine, address _permit3, address _superSignature) {
        engine = Engine(_engine);
        permit3 = Permit3(_permit3);
        superSignature = SuperSignature(_superSignature);
    }

    function route(
        address to,
        Engine.Commands[] calldata commands,
        bytes[] calldata inputs,
        uint256 numTokens,
        uint256 numLPs,
        Permit3.TransferDetails[] calldata permitTransfers,
        Positions.ILRTATransferDetails[] calldata positionTransfers,
        SuperSignature.Verify calldata verify,
        bytes calldata signature
    )
        external
    {
        superSignature.verifyAndStoreRoot(msg.sender, verify, signature);

        return engine.execute(
            to,
            commands,
            inputs,
            numTokens,
            numLPs,
            abi.encode(CallbackData(permitTransfers, positionTransfers, verify.dataHash, msg.sender))
        );
    }

    function executeCallback(
        address[] calldata tokens,
        int256[] calldata tokensDelta,
        bytes32[] calldata lpIDs,
        int256[] calldata lpDeltas,
        bytes calldata data
    )
        external
    {
        if (msg.sender != address(engine)) revert InvalidCaller(msg.sender);
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // build array of transfer requests, then send as a batch
        Permit3.RequestedTransferDetails[] memory requestedTransfer =
            new Permit3.RequestedTransferDetails[](callbackData.permitTransfers.length);

        uint256 j = 0;
        for (uint256 i = 0; i < tokensDelta.length;) {
            int256 delta = tokensDelta[i];

            if (delta > 0 && tokens[i] != address(0)) {
                requestedTransfer[j] = Permit3.RequestedTransferDetails(msg.sender, uint256(delta));

                unchecked {
                    j++;
                }
            }

            unchecked {
                i++;
            }
        }

        if (callbackData.permitTransfers.length > 0) {
            permit3.transferBySuperSignature(
                callbackData.permitTransfers, requestedTransfer, callbackData.payer, callbackData.dataHash
            );
        }

        j = 0;
        for (uint256 i = 0; i < lpIDs.length;) {
            int256 delta = lpDeltas[i];
            bytes32 id = lpIDs[i];

            // if (delta < 0 && id != bytes32(0)) {
            //     engine.transferBySuperSignature(
            //         callbackData.payer,
            //         abi.encode(callbackData.positionTransfers[j]),
            //         // solhint-disable-next-line max-line-length
            //         ILRTA.RequestedTransfer(msg.sender, abi.encode(Positions.ILRTATransferDetails(id,
            // uint256(-delta)))),
            //         callbackData.dataHash[1 + j:]
            //     );

            //     unchecked {
            //         j++;
            //     }
            // }

            unchecked {
                i++;
            }
        }
    }
}