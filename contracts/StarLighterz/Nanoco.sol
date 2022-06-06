//SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "erc721a/contracts/ERC721A.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract LighterzNanoco is
    ERC721A,
    IERC2981,
    AccessControl,
    Pausable,
    ReentrancyGuard
{
    using Counters for Counters.Counter;

    event ContractSealed();
    event BaseURIChanged(string newBaseURI);
    event Withdraw(address indexed account, uint256 amount);
    event ScopeClaimed(
        address indexed scope,
        uint256 tokenId,
        address indexed owner
    );
    event ScopeClaimerUpdated(address indexed scope, bool authorized);

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(string memory baseURI_) ERC721A("Nanoco", "LTZ_N") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);

        customBaseURI = baseURI_;
    }

    /** PAUSE **/

    bool public contractSealed;

    function _beforeTokenTransfers(
        address from,
        address to,
        uint256 tokenId,
        uint256 quantity
    ) internal override whenNotPaused {
        super._beforeTokenTransfers(from, to, tokenId, quantity);
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

    /** ACTIVATION **/

    bool public mintIsActive = true;

    function setMintIsActive(bool mintIsActive_)
        external
        onlyRole(PAUSER_ROLE)
    {
        mintIsActive = mintIsActive_;
    }

    /** MINTING **/

    uint64 public constant MAX_SUPPLY = 3000;
    uint64 public constant MINT_LIMIT_PER_WALLET = 1;

    function giveaway(address address_, uint64 quantity_)
        external
        callerIsUser
        onlyRole(MINTER_ROLE)
        nonReentrant
    {
        require(address_ != address(0), "zero address");

        _safeMintWithPrice(address_, quantity_, 0);
    }

    function mint(uint64 quantity_) external callerIsUser nonReentrant {
        require(mintIsActive, "Mint not active");

        uint64 totalRequired = _getAux(_msgSender()) + quantity_;
        require(
            totalRequired <= MINT_LIMIT_PER_WALLET,
            "Minting limit exceeded"
        );

        _safeMintWithPrice(_msgSender(), quantity_, 0);

        _setAux(_msgSender(), totalRequired);
    }

    /**
     * @notice internal method, _safeMintWithPrice
     * @param recipient_ NFT recipient
     */
    function _safeMintWithPrice(
        address recipient_,
        uint64 quantity_,
        uint256 price_
    ) internal {
        require(quantity_ > 0, "invalid number of tokens");
        require(totalSupply() + quantity_ < MAX_SUPPLY, "Exceeds max supply");

        uint256 amount = price_ * quantity_;
        require(amount <= msg.value, "transaction value is not enough.");

        _safeMint(recipient_, quantity_);

        refundExcessPayment(amount);
    }

    /**
     * @notice when the amount paid by the user exceeds the actual need, the refund logic will be executed.
     * @param amount_ the actual amount that should be paid
     */
    function refundExcessPayment(uint256 amount_) private {
        if (msg.value > amount_) {
            Address.sendValue(payable(_msgSender()), msg.value - amount_);
        }
    }

    function numberMinted(address owner) public view returns (uint256) {
        return _numberMinted(owner);
    }

    function totalMinted() public view returns (uint256) {
        return _totalMinted();
    }

    function exists(uint256 tokenId) public view returns (bool) {
        return _exists(tokenId);
    }

    /** PASS CLAIMING **/

    // Mapping from scope to claiming address
    mapping(address => mapping(uint256 => address)) private claimed;
    // claimer of the nanoco
    mapping(address => bool) private authorizedClaimer;

    /**
     * @notice add a claimed record to the caller scope
     */
    function distribute(uint256 tokenId_) public returns (address) {
        address scope = _msgSender(); // can be any address/contract
        require(authorizedClaimer[scope], "not authorized");
        require(claimable(scope, tokenId_), "Already claimed");

        address owner = ownerOf(tokenId_);

        claimed[scope][tokenId_] = owner;

        emit ScopeClaimed(scope, tokenId_, owner);
        return owner;
    }

    function claimable(address scope_, uint256 tokenId_)
        public
        view
        returns (bool)
    {
        return claimed[scope_][tokenId_] == address(0);
    }

    function setAuthorizedClaimer(address scope_, bool authorized)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(
            authorizedClaimer[scope_] != authorized,
            "Cannot update same value"
        );
        authorizedClaimer[scope_] = authorized;

        emit ScopeClaimerUpdated(scope_, authorized);
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
        override(ERC721A, IERC165, AccessControl)
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
