// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {Address, ERC2981, ERC721, ERC721Enumerable, ERC721Burnable, Ownable, Turnstile} from "./deps.sol";
import {Splitter} from "./splitter.sol";

contract Cantofornia is ERC721, ERC721Enumerable, ERC721Burnable, Ownable, ERC2981 {
    enum WagonState {
        // Starting state
        Alive,
        // State when HP <= 0
        Dead,
        // State when end is reached before HP <= 0
        Successful
    }

    struct NFT {
        // The 
        string tokenUri;
        // The wagon's health value
        uint256 health;
    }

    // Supply tracking
    uint256 public constant maxTokenSupply = 7700;
    uint256 public constant maxCreatorsSupply = 270;
    uint256 private creatorsSupply = 0;
    // uint256 public constant price = 18_480_000_000_000_000_000; // This is 18.48 Canto
    uint256 public constant price = 18_480_000_000_000_000; // This is 0.01848 Canto or 18.48 Finney
    uint256 internal preFillBase = 200;

    // Ownership and metadata tracking
    uint256 IDCount;
    uint256[] IDRepo;
    string[] URIRepo;
    mapping(uint256 => NFT) public tokenMetadata;

    // Calculation constants
    uint256 private constant MIN_HEALTH = 20;
    uint256 private constant MAX_HEALTH = 100;
    
    uint256 internal nonce = 0;

    // External contracts
    Turnstile private turnstile = Turnstile(0x8279528D7E3E5988B24d5ae23D7b80bC86BBA1Cf); // a testnet turnstile
    // Turnstile private turnstile = Turnstile(0xEcf044C5B4b867CFda001101c617eCd347095B44);
    Splitter private splitter;

    constructor() ERC721("Cantofornia", "CTS") {}

    modifier callerIsUser() {
        require(tx.origin == msg.sender, "Cannot be called by a contract");
        _;
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId);
    }

    function setSplitterInfo(address payable splitterAddr) external onlyOwner {
        splitter = Splitter(splitterAddr);
        // 400 / 10000 = 4% royalty rate
        _setDefaultRoyalty(splitterAddr, 400);
        // Set the splitter address as the CSR recipient
        uint256 csrId = turnstile.register(splitterAddr);
        splitter.setWagonCsrId(csrId);
    }

    // Interfaces support
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC2981, ERC721, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function mint() external payable callerIsUser {
        require(totalSupply() <= maxTokenSupply, "Cannot exceed total supply");
        require(msg.value >= price, "Insufficient funds");
        
        // Increment next added tokenId
        IDCount++;

        // Push new tokenId onto the IDRepo
        if (IDCount <= maxTokenSupply) {
            IDRepo.push(IDCount);
        }

        // Get random id and token uri from repos
        uint256 idRandIdx = rand() % IDRepo.length;
        uint256 idToMint = IDRepo[idRandIdx];
        uint256 uriRandIdx = rand() % URIRepo.length;
        string memory tokenUriToMint = URIRepo[uriRandIdx];

        // Randomly generate health
        uint256 health = (rand() % (MAX_HEALTH - MIN_HEALTH)) + MIN_HEALTH;

        // Update state
        NFT memory nft = NFT(tokenUriToMint, health);
        tokenMetadata[idToMint] = nft;
        _safeMint(msg.sender, idToMint);
        removeFromIDRepo(idRandIdx);
        removeFromURIRepo(uriRandIdx);
        
        // Transfer money
        splitter.deposit{value: price}();
        if (msg.value > price) {
            Address.sendValue(payable(msg.sender), msg.value - price);
        }
    }

    // Minting section for creators
    function creatorMint(uint256 quantity) external onlyOwner {
        require(creatorsSupply + quantity <= maxCreatorsSupply, "Cannot exceed total supply");

        uint256 idRandIdx;
        uint256 idToMint;
        uint256 uriRandIdx;
        string memory tokenUriToMint;
        uint256 health;
        NFT memory nft;


        // loop about to be minted nfts
        for (uint256 i = 0; i < quantity; i++) {
            // up one for total IDs count, this number gives us which number is next to be added
            IDCount++;

            // This is used when we want users to fill numbers to pluck for random
            if (IDCount <= maxTokenSupply) {
                IDRepo.push(IDCount);
            }

            // Get random id and token uri from repos
            idRandIdx = rand() % IDRepo.length;
            idToMint = IDRepo[idRandIdx];
            uriRandIdx = rand() % URIRepo.length;
            tokenUriToMint = URIRepo[uriRandIdx];

            // Randomly generate health
            health = (rand() % (MAX_HEALTH - MIN_HEALTH)) + MIN_HEALTH;

            // Update state
            nft = NFT(tokenUriToMint, health);
            tokenMetadata[idToMint] = nft;
            _safeMint(msg.sender, idToMint);
            removeFromIDRepo(idRandIdx);
            removeFromURIRepo(uriRandIdx);
            creatorsSupply++;
        }
    }

    function wagonState(uint tokenId) external view returns (WagonState) {
        _requireMinted(tokenId);
        uint choice = tokenId % 3;
        if (choice == 0) {
            return WagonState.Dead;
        } else if (choice == 1) {
            return WagonState.Alive;
        } else {
            return WagonState.Successful;
        }

        // TODO: Implement HP checking / state lookup logic
    }

    function ownsWagon(address owner, uint256 tokenId) external view returns (bool) {
        _requireMinted(tokenId);
        // throws if realOwner == address(0)
        address realOwner = ownerOf(tokenId);
        return realOwner == owner;
    }

    // Randomization section
    function rand() internal virtual returns (uint256) {
        uint256 randomness = uint256(keccak256(abi.encodePacked(msg.sender, block.difficulty, block.timestamp, nonce)));
        nonce++;
        return randomness;
    }

    function prefillIDs() public onlyOwner {
        for (uint256 i = 1; i <= preFillBase; i++) {
            IDRepo.push(i);
        }
        IDCount = preFillBase;
    }

    function removeFromIDRepo(uint256 index) private {
        IDRepo[index] = IDRepo[IDRepo.length - 1];
        IDRepo.pop();
    }

    function removeFromURIRepo(uint256 index) private {
        URIRepo[index] = URIRepo[URIRepo.length - 1];
        URIRepo.pop();
    }

    // URI section
    function addTokenUris(string[] calldata uris) external onlyOwner {
        require(URIRepo.length + uris.length <= maxTokenSupply, "Cannot add token URIs. Would pass maxTokenSupply");
        for (uint i=0; i < uris.length; i++) {
            URIRepo.push(uris[i]);
        }
        // No events here for subtlety
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        _requireMinted(tokenId);
        return tokenMetadata[tokenId].tokenUri;
    }

    // Utils

    // Withdraw balance if someone donates
    function withdraw() public onlyOwner {
        uint256 balance = address(this).balance;
        payable(msg.sender).transfer(balance);
    }
}
