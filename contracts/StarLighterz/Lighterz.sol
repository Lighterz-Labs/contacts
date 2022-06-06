//SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title Lighterz
 */
contract Lighterz is
    ERC721,
    IERC2981,
    Pausable,
    AccessControl,
    ReentrancyGuard
{
    event ContractSealed();
    event BaseURIChanged(string newBaseURI);
    event Withdraw(address indexed account, uint256 amount);
    event Deposit(address indexed account, uint256 amount);

    event Refunded(
        address indexed from,
        address indexed to,
        uint256 indexed tokenId
    );
    event Revealed(uint256 indexed mpTokenId, uint256 indexed tokenId);

    event MintPassContractAddressChanged(address indexed contractAddress);
    event RefundConfigChanged(RefundConfig config);

    struct RefundConfig {
        uint256 startTime;
        uint256 endTime;
        uint256 price;
        address beneficiary;
    }

    RefundConfig public refundConfig;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    constructor(
        string memory baseURI_,
        address mpContractAddress_,
        address maintainerAddress_,
        string memory displayName_
    ) ERC721(displayName_, "LTZ") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, maintainerAddress_);
        _grantRole(PAUSER_ROLE, maintainerAddress_);

        customBaseURI = baseURI_;
        mintPassContractAddress = mpContractAddress_;
    }

    /** PAUSE **/

    bool public contractSealed;

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override whenNotPaused {
        super._beforeTokenTransfer(from, to, tokenId);
    }

    function pause() external onlyRole(PAUSER_ROLE) notSealed {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) notSealed {
        _unpause();
    }

    function sealContract() external onlyRole(DEFAULT_ADMIN_ROLE) {
        contractSealed = true;
        emit ContractSealed();
    }

    /** MINTING **/

    uint64 public constant MAX_SUPPLY = 5000;

    address public mintPassContractAddress;

    uint256[MAX_SUPPLY] internal _randIndices;
    uint256 private _numberMinted;
    mapping(uint256 => bytes32) private _tokenHashes;

    /**
     * @notice mint is used to randomly generate a token for address_.
     * It can only be called by the Mint Pass contract.
     * @param address_ specify which address will get the token.
     * @param mpTokenId_ defines which tokenId in the mint pass contract this call originates from.
     * @return randomly generated TokenId
     */
    function mint(address address_, uint256 mpTokenId_)
        public
        returns (uint256)
    {
        require(_msgSender() == mintPassContractAddress, "not authorized");
        require(_numberMinted + 1 <= MAX_SUPPLY, "Exceeds max supply");
        uint256 tokenId = getRandomTokenId();
        _safeMint(address_, tokenId);
        unchecked {
            _numberMinted += 1;
        }
        emit Revealed(mpTokenId_, tokenId);
        return tokenId;
    }

    /**
     * @notice mintRemains is used to calculate how many tokens remains
     */
    function mintRemains() public view returns (uint256) {
        return MAX_SUPPLY - totalMinted();
    }

    /**
     * @notice getRandomTokenId is used to randomly select an unused tokenId.
     * @return randomly selected tokenId.
     */
    function getRandomTokenId() internal returns (uint256) {
        unchecked {
            uint256 remain = MAX_SUPPLY - _numberMinted;
            uint256 pos = unsafeRandom() % remain;
            uint256 val = _randIndices[pos] == 0 ? pos : _randIndices[pos];
            _randIndices[pos] = _randIndices[remain - 1] == 0
                ? remain - 1
                : _randIndices[remain - 1];
            return val;
        }
    }

    /**
     * @notice unsafeRandom is used to generate a random number by on-chain randomness.
     * Please note that on-chain random is potentially manipulated by miners, and most scenarios suggest using VRF.
     * @return randomly generated number.
     */
    function unsafeRandom() internal view returns (uint256) {
        unchecked {
            return
                uint256(
                    keccak256(
                        abi.encodePacked(
                            blockhash(block.number - 1),
                            block.difficulty,
                            block.timestamp,
                            _numberMinted,
                            tx.origin
                        )
                    )
                );
        }
    }

    /**
     * @notice totalMinted is used to return the total number of tokens minted.
     * Note that it does not decrease as the token is burnt.
     */
    function totalMinted() public view returns (uint256) {
        return _numberMinted;
    }

    /** REFUND **/

    /**
     * @notice The NFT holder can use this method to perform refund token
     * and a certain amount of ETH will be sent to the caller.
     * @param tokenId_ which token to refund
     */
    function refund(uint256 tokenId_) external callerIsUser nonReentrant {
        require(isRefundEnabled(), "refund has not enabled");
        require(
            address(this).balance > refundConfig.price,
            "insufficient contract funds"
        );

        address from = _msgSender();
        address to = refundConfig.beneficiary;
        require(ownerOf(tokenId_) == from, "caller is not owner");

        safeTransferFrom(from, to, tokenId_);
        Address.sendValue(payable(from), refundConfig.price);

        emit Refunded(from, to, tokenId_);
    }

    /**
     * @notice isRevealEnabled is used to return whether the refund has been enabled
     */
    function isRefundEnabled() public view returns (bool) {
        if (
            refundConfig.endTime > 0 && block.timestamp > refundConfig.endTime
        ) {
            return false;
        }
        return
            refundConfig.startTime > 0 &&
            block.timestamp > refundConfig.startTime &&
            refundConfig.price > 0 &&
            refundConfig.beneficiary != address(0);
    }

    /** CONFIGURE **/

    /**
     * @notice setMintPassContractAddress is used to allow the issuer to modify the mintPassContractAddress in special cases.
     * This process is under the supervision of the community.
     */
    function setMintPassContractAddress(address address_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        mintPassContractAddress = address_;
        emit MintPassContractAddressChanged(address_);
    }

    /**
     * @notice setRefundConfig allows issuer to set refundConfig
     */
    function setRefundConfig(RefundConfig calldata config_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(config_.beneficiary != address(0), "beneficiary is required");
        refundConfig = config_;
        emit RefundConfigChanged(config_);
    }

    /** URI HANDLING **/

    string private customBaseURI;

    function setBaseURI(string memory customBaseURI_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        customBaseURI = customBaseURI_;
        emit BaseURIChanged(customBaseURI_);
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return customBaseURI;
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        return string(abi.encodePacked(super.tokenURI(tokenId), ".token.json"));
    }

    /** PAYOUT **/

    /**
     * @notice issuer have permission to deposit ETH into the contract, which is used to support the refund logic.
     */
    function deposit()
        external
        payable
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        emit Deposit(_msgSender(), msg.value);
    }

    /**
     * @notice issuer withdraws the ETH
     */
    function withdraw() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        uint256 balance = address(this).balance;
        Address.sendValue(payable(_msgSender()), balance);

        emit Withdraw(_msgSender(), balance);
    }

    /** ROYALTIES **/

    function royaltyInfo(uint256, uint256 salePrice)
        external
        view
        override
        returns (address receiver, uint256 royaltyAmount)
    {
        return (address(this), (salePrice * 1000) / 10000);
    }

    // The following functions are overrides required by Solidity.

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, IERC165, AccessControl)
        returns (bool)
    {
        return (interfaceId == type(IERC2981).interfaceId ||
            interfaceId == type(AccessControl).interfaceId ||
            super.supportsInterface(interfaceId));
    }

    /** MODIFIERS **/

    /**
     * @notice for security reasons, CA is not allowed to call sensitive methods.
     */
    modifier callerIsUser() {
        require(tx.origin == _msgSender(), "the caller is another contract");
        _;
    }

    /**
     * @notice function call is only allowed when the contract has not been sealed
     */
    modifier notSealed() {
        require(!contractSealed, "contract sealed");
        _;
    }
}
