// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract User {
    string private fid;
    Transaction[] public txns;
    Product[] private products;
    address private dashboardAddress;

    constructor(address _dashboardAddress) {
        dashboardAddress = _dashboardAddress;
    }

    function addProduct(
        string memory _description,
        string memory _img_url,
        string memory _title,
        string memory _category,
        address _walletAddress,
        address _tokenAddress,
        uint256 _priceInUSD,
        uint256 _quantity
    ) public {
        Product product = new Product(
            msg.sender,
            _description,
            _img_url,
            _title,
            _category,
            _walletAddress,
            _tokenAddress,
            _priceInUSD,
            _quantity
        );
        products.push(product);
        Dashboard(dashboardAddress).addProduct(product);
    }

    function addTransaction(address _tokenAddress, uint256 _amountInUSD, Product _product, uint256 _quantity) public {
        Transaction memory txn = Transaction(_tokenAddress, _amountInUSD, _product, _quantity);
        txns.push(txn);
    }

    function getProducts() public view returns (Product[] memory) {
        return products;
    }

    function increaseProductQuantity(Product _product, uint256 _additionalQuantity) public {
        require(_product.owner() == msg.sender, "Only product owner can increase quantity");
        _product.increaseQuantity(_additionalQuantity);
    }
}

contract Product is Ownable {
    string public description;
    string public img_url;
    string public title;
    string public category;
    address public walletAddress;
    address public tokenAddress;
    uint256 public priceInUSD;
    uint256 public quantity;
    AggregatorV3Interface internal ethUsdPriceFeed;
    AggregatorV3Interface internal tokenEthPriceFeed;
    IUniswapV2Router02 public uniswapRouter;

    constructor(
        address owner,
        string memory _description,
        string memory _img_url,
        string memory _title,
        string memory _category,
        address _walletAddress,
        address _tokenAddress,
        uint256 _priceInUSD,
        uint256 _quantity
    ) Ownable(owner) {
        description = _description;
        img_url = _img_url;
        title = _title;
        category = _category;
        walletAddress = _walletAddress;
        tokenAddress = _tokenAddress;
        priceInUSD = _priceInUSD;
        quantity = _quantity;
    }

    function setPriceFeeds(address _ethUsdPriceFeed, address _tokenEthPriceFeed) public onlyOwner {
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);
        tokenEthPriceFeed = AggregatorV3Interface(_tokenEthPriceFeed);
    }

    function setUniswapRouter(address _uniswapRouter) public onlyOwner {
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
    }

    function getEthUsdPrice() public view returns (int) {
        (, int price, , , ) = ethUsdPriceFeed.latestRoundData();
        return price;
    }

    function getTokenEthPrice() public view returns (int) {
        (, int price, , , ) = tokenEthPriceFeed.latestRoundData();
        return price;
    }

    function getTokenUsdPrice() public view returns (int) {
        int ethUsdPrice = getEthUsdPrice();
        int tokenEthPrice = getTokenEthPrice();
        int tokenUsdPrice = (tokenEthPrice * ethUsdPrice) / (10 ** 18);
        return tokenUsdPrice;
    }

    function getPriceInToken() public view returns (uint256) {
        int tokenUsdPrice = getTokenUsdPrice();
        require(tokenUsdPrice > 0, "Invalid token USD price");
        uint256 priceInToken = (priceInUSD * (10 ** 18)) / uint256(tokenUsdPrice);
        return priceInToken;
    }

    function decreaseQuantity(uint256 _quantity) public {
        require(quantity >= _quantity, "Insufficient quantity");
        quantity -= _quantity;
    }

    function increaseQuantity(uint256 _quantity) public onlyOwner {
        quantity += _quantity;
    }
}

struct Transaction {
    address tokenAddress;
    uint256 amountInUSD;
    Product productAddress;
    uint256 quantity;
}


contract Dashboard {
    mapping(string => User) private users;
    Product[] public allProducts;
    address public constant uniswapRouterAddress = address(0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4);
    AggregatorV3Interface internal ethUsdPriceFeed = AggregatorV3Interface(0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1);
    constructor() public{
    }

    function getUser(string memory _fid) public returns (User) {
        if (address(users[_fid]) == address(0)) {
            users[_fid] = new User(address(this));
        }
        return users[_fid];
    }

    function addProduct(Product product) external {
        allProducts.push(product);
    }

    function getAllProducts() public view returns (Product[] memory) {
        return allProducts;
    }

    function purchaseProduct(string memory _userFID, uint256 _productIndex, uint256 _quantity, address _tokenAddress) public {
        User user = getUser(_userFID);
        Product product = allProducts[_productIndex];
        require(product.quantity() >= _quantity, "Insufficient product quantity");

        uint256 totalAmountInUSD = product.priceInUSD() * _quantity;
        uint256 totalAmountWithFees = totalAmountInUSD;

        // Transfer the tokens from the buyer to the contract
        require(IERC20(_tokenAddress).transferFrom(msg.sender, address(this), totalAmountWithFees), "Transfer of fees failed");

        // Approve Uniswap router to spend the tokens
        require(IERC20(_tokenAddress).approve(uniswapRouterAddress, totalAmountWithFees), "Approve failed");

        // Swap tokens to the product's tokenAddress
        uint256 amountOutMin = getSwapAmountMin(totalAmountInUSD, _tokenAddress, product.tokenAddress());
        swapTokens(_tokenAddress, product.tokenAddress(), totalAmountWithFees, amountOutMin);

        // Transfer the swapped tokens to the product's wallet address
        require(IERC20(product.tokenAddress()).transfer(product.walletAddress(), amountOutMin), "Transfer of product price failed");

        product.decreaseQuantity(_quantity);

        user.addTransaction(product.tokenAddress(), totalAmountInUSD, product, _quantity);
    }

    function swapTokens(address _fromToken, address _toToken, uint256 _amountIn, uint256 _amountOutMin) internal {
        address[] memory path = getPathForTokenToToken(_fromToken, _toToken);
        IUniswapV2Router02(uniswapRouterAddress).swapExactTokensForTokens(
            _amountIn,
            _amountOutMin,
            path,
            address(this),
            block.timestamp + 300
        );
    }

    function getSwapAmountMin(uint256 _amountInUSD, address _fromToken, address _toToken) internal view returns (uint256) {
        // Get the amount of tokens equivalent to _amountInUSD after the swap
        uint256 ethAmount = _amountInUSD * (10 ** 18) / uint256(getEthUsdPrice());
        uint256[] memory amounts = IUniswapV2Router02(uniswapRouterAddress).getAmountsOut(ethAmount, getPathForTokenToToken(_fromToken, _toToken));
        return amounts[amounts.length - 1];
    }
    
    function getPathForTokenToToken(address _fromToken, address _toToken) internal pure returns (address[] memory) {
        address[] memory path = new address[](3);
        path[0] = _fromToken;
        path[1] = IUniswapV2Router02(uniswapRouterAddress).WETH();
        path[2] = _toToken;
        return path;
    }

    function getEthUsdPrice() internal view returns (int) {
        (
            , 
            int price,
            ,
            ,
        ) = ethUsdPriceFeed.latestRoundData();
        return price;
    }
}
