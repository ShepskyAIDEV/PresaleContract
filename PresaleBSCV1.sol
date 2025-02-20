//SPDX-License-Identifier: MIT
//               _    _____                                        _
// __      _____| |__|___ / _ __   __ _ _   _ _ __ ___   ___ _ __ | |_ ___
// \ \ /\ / / _ \ '_ \ |_ \| '_ \ / _` | | | | '_ ` _ \ / _ \ '_ \| __/ __|
//  \ V  V /  __/ |_) |__) | |_) | (_| | |_| | | | | | |  __/ | | | |_\__ \
//   \_/\_/ \___|_.__/____/| .__/ \__,_|\__, |_| |_| |_|\___|_| |_|\__|___/
//                         |_|          |___/
//
pragma solidity 0.8.9;
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

interface Aggregator {
  function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract PresaleBSCV1 is Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable, PausableUpgradeable {
  uint256 public totalTokensSold;
  uint256 public startTime;
  uint256 public endTime;
  uint256 public baseDecimals;
  uint256 public maxTokensToBuy;
  uint256 public currentStep;
  uint256 public checkPoint;
  uint256 public usdRaised;
  uint256 public timeConstant;
  uint256[][3] public rounds;
  uint256[] public prevCheckpoints;
  uint256[] public remainingTokensTracker;
  uint256[] public percentages;
  address[] public wallets;
  address public paymentWallet;
  address public admin;
  bool public dynamicTimeFlag;

  IERC20Upgradeable public USDTInterface;
  Aggregator public aggregatorInterface;
  mapping(address => uint256) public userDeposits;

  event SaleTimeSet(uint256 _start, uint256 _end, uint256 timestamp);
  event SaleTimeUpdated(bytes32 indexed key, uint256 prevValue, uint256 newValue, uint256 timestamp);
  event TokensBought(address indexed user, uint256 indexed tokensBought, address indexed purchaseToken, uint256 amountPaid, uint256 usdEq, uint256 timestamp);
  event MaxTokensUpdated(uint256 prevValue, uint256 newValue, uint256 timestamp);

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() initializer {}

  /**
   * @dev Initializes the contract and sets key parameters
   * @param _oracle Oracle contract to fetch BNB/USDT price
   * @param _usdt USDT token contract address
   * @param _startTime start time of the presale
   * @param _endTime end time of the presale
   * @param _rounds array of round details
   * @param _maxTokensToBuy amount of max tokens to buy
   * @param _paymentWallet address to recive payments
   */
  function initialize(address _oracle, address _usdt, uint256 _startTime, uint256 _endTime, uint256[][3] memory _rounds, uint256 _maxTokensToBuy, address _paymentWallet, bool _dynamicTimeFlag, uint256 _timeConstant) external initializer {
    require(_oracle != address(0), "Zero aggregator address");
    require(_usdt != address(0), "Zero USDT address");
    require(_startTime > block.timestamp && _endTime > _startTime, "Invalid time");
    __Pausable_init_unchained();
    __Ownable_init_unchained();
    __ReentrancyGuard_init_unchained();
    baseDecimals = (10 ** 18);
    aggregatorInterface = Aggregator(_oracle);
    USDTInterface = IERC20Upgradeable(_usdt);
    startTime = _startTime;
    endTime = _endTime;
    rounds = _rounds;
    maxTokensToBuy = _maxTokensToBuy;
    paymentWallet = _paymentWallet;
    dynamicTimeFlag = _dynamicTimeFlag;
    timeConstant = _timeConstant;
    emit SaleTimeSet(startTime, endTime, block.timestamp);
  }

  /**
   * @dev To pause the presale
   */
  function pause() external onlyOwner {
    _pause();
  }

  /**
   * @dev To unpause the presale
   */
  function unpause() external onlyOwner {
    _unpause();
  }

  /**
   * @dev To calculate the price in USD for given amount of tokens.
   * @param _amount No of tokens
   */
  function calculatePrice(uint256 _amount) public view returns (uint256) {
    uint256 USDTAmount;
    uint256 total = checkPoint == 0 ? totalTokensSold : checkPoint;
    require(_amount <= maxTokensToBuy, "Amount exceeds max tokens to buy");
    if (_amount + total > rounds[0][currentStep] || block.timestamp >= rounds[2][currentStep]) {
      require(currentStep < (rounds[0].length - 1), "Wrong params");
      if (block.timestamp >= rounds[2][currentStep]) {
        require(rounds[0][currentStep] + _amount <= rounds[0][currentStep + 1], "Cant Purchase More in individual tx");
        USDTAmount = _amount * rounds[1][currentStep + 1];
      } else {
        uint256 tokenAmountForCurrentPrice = rounds[0][currentStep] - total;
        USDTAmount = tokenAmountForCurrentPrice * rounds[1][currentStep] + (_amount - tokenAmountForCurrentPrice) * rounds[1][currentStep + 1];
      }
    } else USDTAmount = _amount * rounds[1][currentStep];
    return USDTAmount;
  }

  /**
   * @dev To update the sale times
   * @param _startTime New start time
   * @param _endTime New end time
   */
  function changeSaleTimes(uint256 _startTime, uint256 _endTime) external onlyOwner {
    require(_startTime > 0 || _endTime > 0, "Invalid parameters");
    if (_startTime > 0) {
      require(block.timestamp < startTime, "Sale already started");
      require(block.timestamp < _startTime, "Sale time in past");
      uint256 prevValue = startTime;
      startTime = _startTime;
      emit SaleTimeUpdated(bytes32("START"), prevValue, _startTime, block.timestamp);
    }
    if (_endTime > 0) {
      require(_endTime > startTime, "Invalid endTime");
      uint256 prevValue = endTime;
      endTime = _endTime;
      emit SaleTimeUpdated(bytes32("END"), prevValue, _endTime, block.timestamp);
    }
  }

  /**
   * @dev To get latest BNB price in 10**18 format
   */
  function getLatestPrice() public view returns (uint256) {
    (, int256 price, , , ) = aggregatorInterface.latestRoundData();
    price = (price * (10 ** 10));
    return uint256(price);
  }

  function setSplits(address[] memory _wallets, uint256[] memory _percentages) public onlyOwner {
    require(_wallets.length == _percentages.length, "Mismatched arrays");
    delete wallets;
    delete percentages;
    uint256 totalPercentage = 0;

    for (uint256 i = 0; i < _wallets.length; i++) {
      require(_percentages[i] > 0, "Percentage must be greater than 0");
      totalPercentage += _percentages[i];
      wallets.push(_wallets[i]);
      percentages.push(_percentages[i]);
    }

    require(totalPercentage == 100, "Total percentage must equal 100");
  }

  modifier checkSaleState(uint256 amount) {
    require(block.timestamp >= startTime && block.timestamp <= endTime, "Invalid time for buying");
    require(amount > 0, "Invalid sale amount");
    _;
  }

  /**
   * @dev To buy into a presale using USDT
   * @param amount No of tokens to buy
   */
  function buyWithUSDT(uint256 amount) external checkSaleState(amount) whenNotPaused returns (bool) {
    uint256 usdPrice = calculatePrice(amount);
    totalTokensSold += amount;
    if (checkPoint != 0) checkPoint += amount;
    uint256 total = totalTokensSold > checkPoint ? totalTokensSold : checkPoint;
    if (total > rounds[0][currentStep] || block.timestamp >= rounds[2][currentStep]) {
      if (block.timestamp >= rounds[2][currentStep]) {
        checkPoint = rounds[0][currentStep] + amount;
      }
      if (dynamicTimeFlag) {
        manageTimeDiff();
      }
      uint256 unsoldTokens = total > rounds[0][currentStep] ? 0 : rounds[0][currentStep] - total - amount;
      remainingTokensTracker.push(unsoldTokens);
      currentStep += 1;
    }
    userDeposits[_msgSender()] += (amount * baseDecimals);
    usdRaised += usdPrice;
    uint256 ourAllowance = USDTInterface.allowance(_msgSender(), address(this));
    require(usdPrice <= ourAllowance, "Make sure to add enough allowance");
    splitUSDTValue(usdPrice);

    emit TokensBought(_msgSender(), amount, address(USDTInterface), usdPrice, usdPrice, block.timestamp);
    return true;
  }

  /**
   * @dev To buy into a presale using BNB
   * @param amount No of tokens to buy
   */
  function buyWithBNB(uint256 amount) external payable checkSaleState(amount) whenNotPaused nonReentrant returns (bool) {
    uint256 usdPrice = calculatePrice(amount);
    uint256 bnbAmount = (usdPrice * baseDecimals) / getLatestPrice();
    require(msg.value >= bnbAmount, "Less payment");
    uint256 excess = msg.value - bnbAmount;
    totalTokensSold += amount;
    if (checkPoint != 0) checkPoint += amount;
    uint256 total = totalTokensSold > checkPoint ? totalTokensSold : checkPoint;
    if (total > rounds[0][currentStep] || block.timestamp >= rounds[2][currentStep]) {
      if (block.timestamp >= rounds[2][currentStep]) {
        checkPoint = rounds[0][currentStep] + amount;
      }
      if (dynamicTimeFlag) {
        manageTimeDiff();
      }
      uint256 unsoldTokens = total > rounds[0][currentStep] ? 0 : rounds[0][currentStep] - total - amount;
      remainingTokensTracker.push(unsoldTokens);
      currentStep += 1;
    }
    userDeposits[_msgSender()] += (amount * baseDecimals);
    usdRaised += usdPrice;
    splitBNBValue(bnbAmount);
    if (excess > 0) sendValue(payable(_msgSender()), excess);
    emit TokensBought(_msgSender(), amount, address(0), bnbAmount, usdPrice, block.timestamp);
    return true;
  }

  /**
   * @dev Helper funtion to get BNB price for given amount
   * @param amount No of tokens to buy
   */
  function bnbBuyHelper(uint256 amount) external view returns (uint256 bnbAmount) {
    uint256 usdPrice = calculatePrice(amount);
    bnbAmount = (usdPrice * baseDecimals) / getLatestPrice();
  }

  /**
   * @dev Helper funtion to get USDT price for given amount
   * @param amount No of tokens to buy
   */
  function usdtBuyHelper(uint256 amount) external view returns (uint256 usdPrice) {
    usdPrice = calculatePrice(amount);
  }

  function sendValue(address payable recipient, uint256 amount) internal {
    require(address(this).balance >= amount, "Low balance");
    (bool success, ) = recipient.call{value: amount}("");
    require(success, "BNB Payment failed");
  }

  function splitBNBValue(uint256 _amount) internal {
    if (wallets.length == 0) {
      require(paymentWallet != address(0), "Payment wallet not set");
      sendValue(payable(paymentWallet), _amount);
    } else {
      uint256 tempCalc;
      for (uint256 i = 0; i < wallets.length; i++) {
        uint256 amountToTransfer = (_amount * percentages[i]) / 100;
        sendValue(payable(wallets[i]), amountToTransfer);
        tempCalc += amountToTransfer;
      }
      if ((_amount - tempCalc) > 0) {
        sendValue(payable(wallets[wallets.length - 1]), _amount - tempCalc);
      }
    }
  }

  function splitUSDTValue(uint256 _amount) internal {
    if (wallets.length == 0) {
      require(paymentWallet != address(0), "Payment wallet not set");
      (bool success, ) = address(USDTInterface).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", _msgSender(), paymentWallet, _amount));
      require(success, "Token payment failed");
    } else {
      uint256 tempCalc;
      for (uint256 i = 0; i < wallets.length; i++) {
        uint256 amountToTransfer = (_amount * percentages[i]) / 100;
        (bool success, ) = address(USDTInterface).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", _msgSender(), wallets[i], amountToTransfer));
        require(success, "Token payment failed");
        tempCalc += amountToTransfer;
      }
      if ((_amount - tempCalc) > 0) {
        (bool success, ) = address(USDTInterface).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", _msgSender(), wallets[wallets.length - 1], _amount - tempCalc));
        require(success, "Token payment failed");
      }
    }
  }

  function changeMaxTokensToBuy(uint256 _maxTokensToBuy) external onlyOwner {
    require(_maxTokensToBuy > 0, "Zero max tokens to buy value");
    uint256 prevValue = maxTokensToBuy;
    maxTokensToBuy = _maxTokensToBuy;
    emit MaxTokensUpdated(prevValue, _maxTokensToBuy, block.timestamp);
  }

  function changeRoundsData(uint256[][3] memory _rounds) external onlyOwner {
    rounds = _rounds;
  }

  /**
   * @dev To set payment wallet address
   * @param _newPaymentWallet new payment wallet address
   */
  function changePaymentWallet(address _newPaymentWallet) external onlyOwner {
    require(_newPaymentWallet != address(0), "address cannot be zero");
    paymentWallet = _newPaymentWallet;
  }

  /**
   * @dev To get array of round details at once
   * @param _no array index
   */
  function roundDetails(uint256 _no) external view returns (uint256[] memory) {
    return rounds[_no];
  }

  /**
   * @dev To manage time gap between two rounds
   */
  function manageTimeDiff() internal {
    for (uint256 i; i < rounds[2].length - currentStep; i++) {
      rounds[2][currentStep + i] = block.timestamp + i * timeConstant;
    }
  }

  /**
   * @dev To set time constant for manageTimeDiff()
   * @param _timeConstant time in <days>*24*60*60 format
   */
  function setTimeConstant(uint256 _timeConstant) external onlyOwner {
    timeConstant = _timeConstant;
  }

  /**
   * @dev To increment the rounds from backend
   */
  function incrementCurrentStep() external {
    require(msg.sender == admin || msg.sender == owner(), "caller not admin or owner");
    prevCheckpoints.push(checkPoint);
    if (dynamicTimeFlag) {
      manageTimeDiff();
    }
    if (checkPoint < rounds[0][currentStep]) {
      if (currentStep == 0) {
        remainingTokensTracker.push(rounds[0][currentStep] - totalTokensSold);
      } else {
        remainingTokensTracker.push(rounds[0][currentStep] - checkPoint);
      }
      checkPoint = rounds[0][currentStep];
    }
    currentStep++;
  }

  /**
   * @dev To set time shift functionality on/off
   * @param _dynamicTimeFlag bool value
   */
  function setDynamicTimeFlag(bool _dynamicTimeFlag) external onlyOwner {
    dynamicTimeFlag = _dynamicTimeFlag;
  }

  /**
   * @dev To set admin
   * @param _admin new admin wallet address
   */
  function setAdmin(address _admin) external onlyOwner {
    admin = _admin;
  }

  /**
   * @dev To change details of the round
   * @param _step round for which you want to change the details
   * @param _checkpoint token tracker amount
   */
  function setCurrentStep(uint256 _step, uint256 _checkpoint) external onlyOwner {
    currentStep = _step;
    checkPoint = _checkpoint;
  }

  /**
   * @dev     Function to return remainingTokenTracker Array
   */
  function trackRemainingTokens() external view returns (uint256[] memory) {
    return remainingTokensTracker;
  }

  /**
   * @dev     To update remainingTokensTracker Array
   * @param   _unsoldTokens  input parameters in uint256 array format
   */
  function setRemainingTokensArray(uint256[] memory _unsoldTokens) public {
    require(msg.sender == admin || msg.sender == owner(), "caller not admin or owner");
    delete remainingTokensTracker;
    for (uint256 i; i < _unsoldTokens.length; i++) {
      remainingTokensTracker.push(_unsoldTokens[i]);
    }
  }
}
