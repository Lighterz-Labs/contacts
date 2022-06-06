//SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "erc721a/contracts/ERC721A.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/Address.sol";

// NFT interface
abstract contract LighterzInterface {
    // mint a NFT to the address
    function mint(address address_, uint256 mpTokenId_)
        public
        virtual
        returns (uint256);

    // get how many tokens remain
    function mintRemains() public view virtual returns (uint256);
}

// Nanoco NFT interface
abstract contract LighterzNanocoInterface {
    // distribute by MintPass
    function distribute(uint256 tokenId_) public virtual returns (address);

    // get the owner of tokenId
    function ownerOf(uint256 tokenId_) public view virtual returns (address);

    // check if claimable of the tokenId
    function claimable(address scope_, uint256 tokenId_)
        public
        view
        virtual
        returns (bool);
}

/**
 * @title LighterzMintPass
 */
contract LighterzMintPass is
    ERC721A,
    IERC2981,
    AccessControl,
    Pausable,
    ReentrancyGuard
{
    event ContractSealed();
    event BaseURIChanged(string newBaseURI);
    event Withdraw(address indexed account, uint256 amount);

    event NanocoSaleConfigChanged(NanocoSaleConfig config);
    event WhitelistSaleConfigChanged(WhitelistSaleConfig config);
    event PublicSaleConfigChanged(PublicSaleConfig config);
    event RevealConfigChanged(RevealConfig config);

    struct NanocoSaleConfig {
        uint256 startTime;
        uint256 endTime;
        uint256 price;
        // nanoco contract
        address contractAddress;
    }

    struct WhitelistSaleConfig {
        uint256 startTime;
        uint256 endTime;
        uint256 price;
        // merkle root
        bytes32 merkleRoot;
        // mint quota
        uint64 quota;
    }

    struct PublicSaleConfig {
        uint256 startTime;
        uint256 price;
    }

    struct RevealConfig {
        uint256 startTime;
        // target collectionA
        address contractAddressA;
        // target collectionB
        address contractAddressB;
    }

    NanocoSaleConfig public nanocoSaleConfig;
    WhitelistSaleConfig public whitelistSaleConfig;
    PublicSaleConfig public publicSaleConfig;
    RevealConfig public revealConfig;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(string memory baseURI_)
        ERC721A("Pass: Into The Forbidden-907", "LTZ_MP")
    {
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

    /** MINTING **/

    uint64 public constant MAX_SUPPLY = 10000;
    uint64 public constant MAX_TOKEN_PER_MINT = 5;

    /**
     * @notice giveaway is used for airdropping to specific addresses.
     * The issuer also reserves tokens through this method.
     * This process is under the supervision of the community.
     * @param address_ the target address of airdrop
     * @param quantity_ quantity of airdrop
     */
    function giveaway(address address_, uint64 quantity_)
        external
        callerIsUser
        onlyRole(MINTER_ROLE)
        nonReentrant
    {
        require(address_ != address(0), "zero address");

        _safeMintWithPrice(address_, quantity_, 0);
    }

    /**
     * @notice mintByNanocoPass is used for nanoco sale.
     * @param nanocoId_ nanoco NFT tokenId
     */
    function mintByNanocoPass(uint256 nanocoId_)
        external
        payable
        callerIsUser
        nonReentrant
    {
        require(isNanocoSaleEnabled(), "nanoco sale has not enabled");
        // call nanoco contract to check
        LighterzNanocoInterface nanocoContract = LighterzNanocoInterface(
            nanocoSaleConfig.contractAddress
        );
        require(
            nanocoContract.ownerOf(nanocoId_) == _msgSender(),
            "caller is not nanoco owner"
        );
        require(
            nanocoContract.claimable(address(this), nanocoId_),
            "nanocoId is not claimable"
        );

        address target = nanocoContract.distribute(nanocoId_);
        require(target == _msgSender(), "caller should be the target");

        _safeMintWithPrice(_msgSender(), 1, getNanocoSalePrice());
    }

    /**
     * @notice mintByWhitelist is used for whitelist sale.
     * @param quantity_ quantity
     * @param signature_ merkel proof
     */
    function mintByWhitelist(uint64 quantity_, bytes32[] calldata signature_)
        external
        payable
        callerIsUser
        nonReentrant
    {
        require(isWhitelistSaleEnabled(), "whitelist sale has not enabled");
        require(
            isWhitelistAddress(_msgSender(), signature_),
            "not in whitelist or invalid"
        );

        uint64 whitelistMintAmount = _getAux(_msgSender()) + quantity_;
        require(
            whitelistMintAmount <= whitelistSaleConfig.quota,
            "Minting limit exceeded"
        );

        _safeMintWithPrice(_msgSender(), quantity_, getWhitelistSalePrice());

        _setAux(_msgSender(), whitelistMintAmount);
    }

    /**
     * @notice publicSale is used for public sale.
     * @param quantity_ quantity
     */
    function mintByPublic(uint64 quantity_)
        external
        payable
        callerIsUser
        nonReentrant
    {
        require(isPublicSaleEnabled(), "public sale has not enabled");
        _safeMintWithPrice(_msgSender(), quantity_, getPublicSalePrice());
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
        require(quantity_ > 0, "Invalid number of tokens");
        require(
            quantity_ <= MAX_TOKEN_PER_MINT,
            "no more then MAX_TOKEN_PER_MINT"
        );
        require(totalMinted() + quantity_ < MAX_SUPPLY, "Exceeds max supply");

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

    /**
     * @notice isNanocoSaleEnabled is used to return whether nanoco sale has been enabled.
     */
    function isNanocoSaleEnabled() public view returns (bool) {
        if (
            nanocoSaleConfig.endTime > 0 &&
            block.timestamp > nanocoSaleConfig.endTime
        ) {
            return false;
        }
        return
            nanocoSaleConfig.startTime > 0 &&
            block.timestamp > nanocoSaleConfig.startTime &&
            nanocoSaleConfig.price > 0 &&
            nanocoSaleConfig.contractAddress != address(0);
    }

    /**
     * @notice isWhitelistSaleEnabled is used to return whether whitelist sale has been enabled.
     */
    function isWhitelistSaleEnabled() public view returns (bool) {
        if (
            whitelistSaleConfig.endTime > 0 &&
            block.timestamp > whitelistSaleConfig.endTime
        ) {
            return false;
        }
        return
            whitelistSaleConfig.startTime > 0 &&
            block.timestamp > whitelistSaleConfig.startTime &&
            whitelistSaleConfig.price > 0 &&
            whitelistSaleConfig.merkleRoot != "";
    }

    /**
     * @notice isPublicSaleEnabled is used to return whether the public sale has been enabled.
     */
    function isPublicSaleEnabled() public view returns (bool) {
        return
            publicSaleConfig.startTime > 0 &&
            block.timestamp > publicSaleConfig.startTime &&
            publicSaleConfig.price > 0;
    }

    /**
     * @notice isWhitelistAddress is used to verify whether the given address_ and signature_ belong to merkleRoot.
     * @param address_ address of the caller
     * @param signature_ merkle proof
     */
    function isWhitelistAddress(address address_, bytes32[] calldata signature_)
        public
        view
        returns (bool)
    {
        if (whitelistSaleConfig.merkleRoot == "") {
            return false;
        }
        return
            MerkleProof.verify(
                signature_,
                whitelistSaleConfig.merkleRoot,
                keccak256(abi.encodePacked(address_))
            );
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

    /** REVEAL **/

    /**
     * @notice reveal is used to open the blind box.
     * @param tokenId_ tokenId of the blind box to be revealed.
     * @return tokenId after revealing the blind box.
     */
    function reveal(uint256 tokenId_)
        external
        callerIsUser
        nonReentrant
        returns (address, uint256)
    {
        require(isRevealEnabled(), "reveal has not enabled");
        require(ownerOf(tokenId_) == _msgSender(), "caller is not owner");

        _burn(tokenId_);

        LighterzInterface contractA = LighterzInterface(
            revealConfig.contractAddressA
        );
        LighterzInterface contractB = LighterzInterface(
            revealConfig.contractAddressB
        );

        // rand to choose which contract to mint
        LighterzInterface contractToMint;
        unchecked {
            uint256 remainA = contractA.mintRemains();
            uint256 remainB = contractB.mintRemains();

            if (remainA == 0) {
                contractToMint = contractB;
            } else if (remainB == 0) {
                contractToMint = contractA;
            } else {
                uint256 pos = unsafeRandom() % (remainA + remainB);
                contractToMint = pos < remainA ? contractA : contractB;
            }
        }

        uint256 newMintTokenId = contractToMint.mint(_msgSender(), tokenId_);
        return (address(contractToMint), newMintTokenId);
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
                            totalMinted(),
                            tx.origin
                        )
                    )
                );
        }
    }

    /**
     * @notice isRevealEnabled is used to return whether the reveal has been enabled.
     */
    function isRevealEnabled() public view returns (bool) {
        return
            revealConfig.startTime > 0 &&
            block.timestamp > revealConfig.startTime &&
            revealConfig.contractAddressA != address(0) &&
            revealConfig.contractAddressB != address(0);
    }

    /** CONFIGURE **/

    /**
     * @notice getNanocoSalePrice is used to get the price of the nanoco sale.
     * @return price
     */
    function getNanocoSalePrice() public view returns (uint256) {
        return whitelistSaleConfig.price;
    }

    /**
     * @notice getWhitelistSalePrice is used to get the price of the whitelist sale.
     * @return price
     */
    function getWhitelistSalePrice() public view returns (uint256) {
        return whitelistSaleConfig.price;
    }

    /**
     * @notice getPublicSalePrice is used to get the price of the public sale.
     * @return price
     */
    function getPublicSalePrice() public view returns (uint256) {
        return publicSaleConfig.price;
    }

    /**
     * @notice setNanocoSaleConfig is used to set the configuration related to nanoco sale.
     * This process is under the supervision of the community.
     * @param config_ config
     */
    function setNanocoSaleConfig(NanocoSaleConfig calldata config_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(config_.price > 0, "sale price must greater than zero");
        nanocoSaleConfig = config_;
        emit NanocoSaleConfigChanged(config_);
    }

    /**
     * @notice setWhitelistSaleConfig is used to set the configuration related to whitelist sale.
     * This process is under the supervision of the community.
     * @param config_ config
     */
    function setWhitelistSaleConfig(WhitelistSaleConfig calldata config_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(config_.price > 0, "sale price must greater than zero");
        whitelistSaleConfig = config_;
        emit WhitelistSaleConfigChanged(config_);
    }

    /**
     * @notice setPublicSaleConfig is used to set the configuration related to public sale.
     * This process is under the supervision of the community.
     * @param config_ config
     */
    function setPublicSaleConfig(PublicSaleConfig calldata config_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(config_.price > 0, "sale price must greater than zero");
        publicSaleConfig = config_;
        emit PublicSaleConfigChanged(config_);
    }

    /**
     * @notice setRevealConfig is used to set the configuration related to reveal.
     * This process is under the supervision of the community.
     * @param config_ config
     */
    function setRevealConfig(RevealConfig calldata config_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        revealConfig = config_;
        emit RevealConfigChanged(config_);
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
