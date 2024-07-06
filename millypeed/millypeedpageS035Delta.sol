// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {ERC1155Delta} from "erc1155delta/contracts/ERC1155Delta.sol";
import {ERC1155DeltaQueryable} from "erc1155delta/contracts/extensions/ERC1155DeltaQueryable.sol";
import {TokenURIConversion} from "erc1155delta/contracts/wrapper/TokenURIConversion.sol";

import {Ownable} from "solady/src/auth/Ownable.sol";
import {OwnableRoles} from "solady/src/auth/OwnableRoles.sol";

import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {ERC2981} from "solady/src/tokens/ERC2981.sol";
import {OperatorFilterer} from "closedsea/src/OperatorFilterer.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {LibBitmap} from "solady/src/utils/LibBitmap.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {LibString} from "solady/src/utils/LibString.sol";
import {Base64} from "solady/src/utils/Base64.sol";

interface ProxyRegistry {
    function proxies(address) external view returns (address);
}

/**
 * @title Milly
 * @notice Milly is an ERC1155Delta compliant contract for managing a collection of unique NFTs.
 *         It supports royalty payments, operator filtering, and advanced minting and burning functionalities.
 * @dev Inherits from ERC1155DeltaQueryable, Ownable, OwnableRoles, ReentrancyGuard, ERC2981, OperatorFilterer.
 */

contract Milly is
    ERC1155DeltaQueryable,
    Ownable,
    OwnableRoles,
    ReentrancyGuard
{
    using Base64 for *;
    using SafeMath for uint256;
    using LibString for string;
    using LibString for uint256;
    using SafeTransferLib for address;
    using LibBitmap for LibBitmap.Bitmap;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           ERRORS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error OutOfMilly();
    error InsufficientPayment();
    error EmptyMark();
    error InvalidTokenId();
    error NotAuthorized();
    error InvalidCollaboration();

    /// @dev Seed for role slots.
    uint256 private constant _ROLE_SLOT_SEED = 0x8b78c6d8;

    /// @notice Role identifier for admin roles.
    uint256 public constant ADMIN_ROLE = _ROLE_0;
    /// @notice Maximum supply per square foot.
    uint256 public constant MAX_PER_SQ_FT = 69420;

    /// @dev Tracks the current token ID for minting.
    uint256 _currentTokenId = 1;

    /// @dev Flag for allowing gasless trading.
    bool private _gaslessTrading;

    /// @notice Royalty parts per million.
    uint256 private _royaltyPartsPerMillion;
    /// @notice Default receiver for royalties.
    address public defaultRoyaltyReceiver;
    /// @notice Price per pixel.
    uint256 public _pricePerPix;

    /// @notice Name of the contract.
    string public constant name = "Millypeed";
    /// @notice Symbol of the contract.
    string public constant symbol = "Millypeed";

    /// @notice Data proxy URI for token metadata.
    string public _dataProxyUri;
    /// @notice Threshold for some custom logic.
    uint256 public _threshold;
    /// @notice Sum of klons (custom metric).
    uint256 public _klonSum;

    /// @notice Event emitted when a chunk is created.
    event Chunk(
        uint256 indexed id,
        uint256 indexed position,
        uint256 ymax,
        uint256 ymaxLegal,
        uint256 nbpix,
        bytes image
    );

    /// @notice Event emitted when a batch of chunks is created.
    event ChunkBatch(
        uint256 indexed startId,
        uint256 indexed position,
        uint256 ymax,
        uint256 ymaxLegal,
        uint256 nbpix,
        bytes image
    );

    /// @notice Event emitted when the price is updated.
    event PriceUpdated(uint256 newPrice);
    /// @notice Event emitted when the threshold is updated.
    event ThresholdUpdated(uint256 newThreshold);

    /// @notice Flag for enabling operator filtering.
    bool public operatorFilteringEnabled;

    /**
     * @notice Constructor to initialize the contract with URI, threshold, and price.
     * @param uri_ The base URI for token metadata.
     * @param initialThreshold The initial threshold value.
     * @param initialPrice The initial price per pixel.
     */
    constructor(
        string memory uri_,
        uint256 initialThreshold,
        uint256 initialPrice
    ) ERC1155Delta(uri_) {
        _threshold = initialThreshold;
        _pricePerPix = initialPrice;
        _royaltyPartsPerMillion = 50_000; //5%
        _gaslessTrading = true;

        defaultRoyaltyReceiver = 0x3395f8794e8D0Ff3b9b4b43f50f72Ea2d5E61d2c;
        operatorFilteringEnabled = true;

        _initializeOwner(msg.sender);
    }

    /**
     * @notice Modifier to restrict access to owner or curators.
     */
    modifier onlyOwnerOrCurator() {
        _checkOwnerOrRoles(ADMIN_ROLE);
        _;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         .EXE                               */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice This function allows a user to mint new tokens in the contract.
     * It checks if the provided ymax is within the allowed range, verifies that the sender has sent enough Ether (in terms of `_pricePerPix`) for the number of pixels nbpix, ensures that there's an image and that msg.value >= nbpix * _pricePerPix holds true.
     * If all checks pass, it mints new tokens to the sender and emits a Chunk event with details about the chunk drawn by the user.
     *
     * @dev This function is payable which means that Ether can be sent along with the transaction. The amount of Ether sent must match the total price for all pixels nbpix multiplied by `_pricePerPix` in order to execute this function successfully.
     *
     * @param position The position of the chunk on the canvas.
     * @param ymax The maximum value of y coordinate of the chunk.
     * @param nbpix The number of pixels that constitute the chunk.
     * @param image A bytes array representing the image data of the chunk.
     */
    function draw2438054C(
        uint256 position,
        uint256 ymax,
        uint256 nbpix,
        bytes calldata image
    ) external payable nonReentrant {
        require(
            ymax * 1000000 <= 192 * 1000000 + _klonSum * _threshold,
            "Out of milly"
        );
        require(msg.value >= nbpix * _pricePerPix, "Not enough eth");
        require(nbpix > 0, "Cannot send empty mark");

        uint256 startTokenId = _nextTokenId();
        _mint(msg.sender, nbpix);

        _klonSum += nbpix;
        emit Chunk(
            startTokenId,
            position,
            ymax,
            192 * 1000000 + _klonSum * _threshold,
            nbpix,
            image
        );
    }

    /**
     * @notice Function to check if an address is a contract.
     * @param account The address to check.
     * @return bool indicating if the address is a contract.
     */
    function isContract(address account) external view returns (bool) {
        bytes32 codehash;
        bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        assembly {
            codehash := extcodehash(account)
        }
        return (codehash != accountHash && codehash != 0x0);
    }

    /**
     * @notice Function to get page information.
     * @return supply The total supply of tokens.
     * @return threshold The current threshold value.
     * @return klonTotal The total number of klons.
     * @return price The current price per pixel.
     */
    function getPageInfo()
        external
        view
        returns (
            uint256 supply,
            uint256 threshold,
            uint256 klonTotal,
            uint256 price
        )
    {
        return (_totalMinted(), _threshold, _klonSum, _pricePerPix);
    }

    /**
     * @notice Function to get the base URI for a token.
     * @param _tokenId The token ID.
     * @return string The base URI.
     */
    function baseUri(uint256 _tokenId)
        public
        view
        virtual
        returns (string memory)
    {
        if (_tokenId >= _nextTokenId()) revert InvalidTokenId();

        bytes memory baseURI = (
            abi.encodePacked(
                "{",
                '"description": "Milly","external_url": "https://pepecoin.io","animation_url": "',
                _dataProxyUri,
                _tokenId.toString(),
                '","image":"ipfs://QmYzoRxkqoRK22KAiwL5NP1rdWJ92DW38AzYwduK246h9h/"',
                "}"
            )
        );

        return
            string(
                abi.encodePacked(
                    "data:application/json;base64,",
                    baseURI.encode()
                )
            );
    }

    /**
     * @notice Function to get the URI for a token.
     * @param _tokenId The token ID.
     * @return string The URI.
     */
    function uri(uint256 _tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        if (_tokenId >= _nextTokenId()) revert InvalidTokenId();
        return TokenURIConversion.convert(_dataProxyUri, _tokenId);
    }

    /**
     * @notice Function to get the total supply of tokens.
     * @return uint256 The total supply.
     */
    function totalSupply() public view returns (uint256) {
        unchecked {
            return _currentTokenId - 1; // Starts at index 1
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CURATE                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Function to grant curator roles to users.
     * @param users The array of user addresses.
     */
    function grantCuratorRoles(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            _grantRoles(users[i], ADMIN_ROLE);
        }
    }

    /**
     * @notice Function to revoke the curator role from a user.
     * @param user The address of the user.
     */

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     ERC2981 & OPERATOR                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Function to get royalty information.
     * @param salePrice The sale price of the token.
     * @return receiver The address of the royalty receiver.
     * @return royaltyAmount The amount of royalties.
     */

    function royaltyInfo(uint256, uint256 salePrice)
        public
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        receiver = owner();
        royaltyAmount = (salePrice * _royaltyPartsPerMillion) / 1_000_000;
    }

    /**
     * @notice Function to check if an operator is approved for all tokens of an account.
     * @param account The address of the account.
     * @param operator The address of the operator.
     * @return bool indicating if the operator is approved for all tokens.
     */

    function isApprovedForAll(address account, address operator)
        public
        view
        override
        returns (bool)
    {
        ProxyRegistry proxyRegistry = ProxyRegistry(
            0xa5409ec958C83C3f309868babACA7c86DCB077c1
        );
        if (_gaslessTrading && proxyRegistry.proxies(account) == operator) {
            return true;
        }
        return super.isApprovedForAll(account, operator);
    }

    /**
     * @notice Function to check if the contract supports a given interface.
     * @param interfaceId The interface ID.
     * @return bool indicating if the interface is supported.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155Delta)
        returns (bool)
    {
        return
            interfaceId == type(ERC2981).interfaceId ||
            interfaceId == 0x01ffc9a7 || // ERC165
            interfaceId == 0xd9b67a26 || // ERC165 Interface ID for ERC1155
            interfaceId == 0x0e89341c; // ERC165 Interface ID for ERC1155MetadataURI
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CONFIG                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Function to allow gasless listing.
     * @param allow Boolean flag to allow or disallow gasless listing.
     */
    function setAllowGaslessListing(bool allow) public onlyOwner {
        _gaslessTrading = allow;
    }

    /**
     * @notice Function to set the data proxy URI.
     * @param newProxy The new data proxy URI.
     */
    function setDataProxyUri(string calldata newProxy) public onlyOwner {
        _dataProxyUri = newProxy; // ex metadata: https://example.com/spot/{id} of canvas
    }

    /**
     * @notice Function to set the threshold value.
     * @param threshold The new threshold value.
     */
    function setThreshold(uint256 threshold) public onlyOwner {
        _threshold = threshold;
        emit ThresholdUpdated(threshold);
    }

    /**
     * @notice Function to set the price per pixel.
     * @param price The new price per pixel.
     */
    function setPrice(uint256 price) public onlyOwner {
        _pricePerPix = price;
        emit PriceUpdated(price);
    }

    /**
     * @notice Function to set the royalty parts per million.
     * @param newValue The new value for royalty parts per million.
     */
    function setRoyaltyPPM(uint256 newValue) public onlyOwner {
        require(newValue < 1_000_000, "Must be < 1e6");
        _royaltyPartsPerMillion = newValue;
    }

    /**
     * @notice Function to enable or disable operator filtering.
     * @param value Boolean flag to enable or disable operator filtering.
     */
    function setOperatorFilteringEnabled(bool value) public onlyOwner {
        operatorFilteringEnabled = value;
    }

    /**
     * @notice Internal function to check if operator filtering is enabled.
     * @return bool indicating if operator filtering is enabled.
     */
    function _operatorFilteringEnabled() internal view returns (bool) {
        return operatorFilteringEnabled;
    }

    /**
     * @notice Internal function to check if an operator is a priority operator.
     * @param operator The address of the operator.
     * @return bool indicating if the operator is a priority operator.
     */
    function _isPriorityOperator(address operator)
        internal
        pure
        returns (bool)
    {
        // https://etherscan.io/address/0x1E0049783F008A0085193E00003D00cd54003c71
        // https://sepolia.etherscan.io/address/0x1E0049783F008A0085193E00003D00cd54003c71
        return operator == address(0x1E0049783F008A0085193E00003D00cd54003c71);
    }

    /**
     * @notice Function to withdraw all ETH from the contract.
     */
    function withdraw() external onlyOwner nonReentrant {
        _safeTransferETH(msg.sender, address(this).balance);
    }

    /**
     * @notice Internal function to safely transfer ETH.
     * @param to The recipient address.
     * @param amount The amount of ETH to transfer.
     */
    function _safeTransferETH(address to, uint256 amount) private {
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    /**
     * @notice Function to withdraw all ERC20 tokens from the contract.
     * @param erc20Token The ERC20 token contract.
     */
    function withdrawERC20(ERC20 erc20Token) public onlyOwner {
        erc20Token.transfer(msg.sender, erc20Token.balanceOf(address(this)));
    }
}
