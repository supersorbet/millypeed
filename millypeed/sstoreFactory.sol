import {LibClone} from "solady/src/utils/LibClone.sol";
import {CloneableBites52} from "./bitesDraft.sol";

pragma solidity ^0.8.20;

contract Bites52Factory {
    using LibClone for address;

    address public immutable implementation;

    event birth(
        address indexed token,
        address owner,
        string name,
        string symbol,
        uint256 initialSupply
    );

    constructor(address _implementation) {
        implementation = _implementation;
    }

    function forgeIt(
        uint256 initialSupply,
        address owner,
        string memory name,
        string memory symbol
    ) external returns (address token) {
        bytes memory initData = abi.encodeWithSelector(
            CloneableBites52.initialize.selector,
            initialSupply,
            owner,
            name,
            symbol
        );
        token = implementation.clone(initData);
        //    emit birth(token, owner, name, symbol, initialSupply);
    }

    function createTokenDeterministic(
        uint256 initialSupply,
        address owner,
        string memory name,
        string memory symbol,
        bytes32 salt
    ) external returns (address token) {
        bytes memory initData = abi.encodeWithSelector(
            CloneableBites52.initialize.selector,
            initialSupply,
            owner,
            name,
            symbol
        );
        token = implementation.cloneDeterministic(initData, salt);
        //    emit birth(token, owner, name, symbol, initialSupply);
    }

    function predictDeterministicAddress(bytes32 salt)
        external
        view
        returns (address)
    {
        return
            implementation.predictDeterministicAddress(
                bytes(""),
                salt,
                address(this)
            );
    }
}
