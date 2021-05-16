pragma solidity ^0.6.0;

import "../Common/OrderStore.sol";
import "./UniswapInterface.sol";


interface IExchangeManager {
    function burnUsableTradeCount(address _userAddr, uint256 _burnedNumber) external;
    function maxNumberPerAMMSwap() view external returns(uint256);
    function usableTradeCountMap(address user) view external returns(uint256);
}


contract AMMController is Ownable, IStructureInterface, OrderStore {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    address public constant SUSHI_ROUTER = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;
    address public constant UNISWAP_ROUTER = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;
    
    address public Routers = [SUSHI_ROUTER, UNISWAP_ROUTER];
    address private bestSwapRouter;
    uint256 public maxNumberPerSwap = 20;

    struct PairInfo {
        address token0;
        address token1;   // base token, 如usdt, usdc, husd...
    }

    EnumerableSet.AddressSet private pairList;  // 交易对列表
    mapping(address => mapping(address => address)) public registerPairMap;
    mapping(address => PairInfo) pairInfoMap;
    
    event SwapSuccess(address indexed owner, address indexed spender, uint value);
    
    constructor () public {        
    }

    // 增加支持的交易对
    function addPairs(address baseToken, address[] memory swappedTokens) public onlyOwner {
        uint256 length = pairList.length();
        for (uint256 i = 0; i < swappedTokens.length; i++) {
            address swappedToken = swappedTokens[i];
            if (pairMap[baseToken][swappedToken] == address(0) && pairMap[swappedToken][baseToken] == address(0)) {
                pairMap[baseToken][swappedToken] = address(length + 1);
                pairInfoMap[address(length + 1)] = PairInfo(swappedToken, baseToken);
                length += 1;
                pairList.add(pairMap[baseToken][swappedToken]);
            }
        }
    }

    function pairNumber() view public returns(uint256) {
        return pairList.length();
    }

    function getPairInfo(uint256 index) view public returns(address, address, address) {
        require(pairList.length() > index, "Index is out of range.");
        address pairAddr = pairList.at(index);
        PairInfo memory pairInfo = pairInfoMap[pairAddr];
        return (pairAddr, pairInfo.token0, pairInfo.token1);
    }

    function getUniswapPairAddr(address _pairAddr) public returns(address) {
        address token0 = pairInfoMap[_pairAddr].token0;
        address token1 = pairInfoMap[_pairAddr].token1;
        address uniswapFactory = IUniswapV2Router02(UNISWAP_ROUTER).factory();
        address uniswapPair = IUniswapV2Factory(uniswapFactory).getPair(token0, token1);
        return uniswapPair;
    } 

    function getSushiPairAddr(address _pairAddr) public returns(address) {
        address token0 = pairInfoMap[_pairAddr].token0;
        address token1 = pairInfoMap[_pairAddr].token1;
        address sushiFactory = IUniswapV2Router02(SUSHI_ROUTER).factory();
        address sushiPair = IUniswapV2Factory(sushiFactory).getPair(token0, token1);
        return sushiPair;
    } 

    // 评估最佳交易路径，包括订单、UniSwap和SushiSwap
    function evaluateBestSwapPath(address _pairAddr, bool _bBuyToken0, uint256 _spotPrice, uint256 _inAmount, uint256 _minOutAmount) 
        public returns(bool, address[] memory, uint256[] memory) {
        address token0 = pairInfoMap[_pairAddr].token0;
        address token1 = pairInfoMap[_pairAddr].token1;
        address[] memory path = _bBuyToken0 ? [token1, token0] : [token0, token1];

        (uint256 count, uint256[] memory orderIds, uint256 matchedAmount, uint256 inAmountU) = getMatchedOrderIdsBySpotPrice(_pairAddr, _bBuyToken0, _spotPrice, _inAmount);
        if ((_bBuyToken0 && matchedAmount >= _minOutAmount) || (!_bBuyToken0 && matchedAmount >= _inAmount)) {
            address[] memory bestPath = new address[](1);
            uint256[] memory inAmounts = new uint256[](1);
            bestPath[0] = _pairAddr;
            inAmounts[0] = inAmount;
            return (true, bestPath, inAmounts);
        }
        
        uint256 matchSourceNum = (count > 0) ? 3 : 2;
        address[] memory bestPath = new address[](matchSourceNum);
        uint256[] memory inAmounts = new uint256[](matchSourceNum);

        uint index = 0;
        if (count > 0) {  // 表示匹配到自己的订单薄
            bestPath[index] = _pairAddr;
            inAmounts[index] = _bBuyToken0 ? inAmountU : matchedAmount;
            _inAmount = _inAmount.sub(inAmounts[0]);
            index++;
        }

        address uniswapFactory = IUniswapV2Router02(UNISWAP_ROUTER).factory();
        address sushiFactory = IUniswapV2Router02(SUSHI_ROUTER).factory();

        address uniswapPair = IUniswapV2Factory(uniswapFactory).getPair(token0, token1);
        address sushiPair = IUniswapV2Factory(sushiFactory).getPair(token0, token1);

        (uint256 uniReserve0, uint256 uniReserve1, ) = IUniswapV2Pair(uniswapPair).getReserves();
        (uint256 sushiReserve0, uint256 suhiReserve1, ) = IUniswapV2Pair(sushiPair).getReserves();

        // 仅从uniswap或sushiswap进行兑换
        uint256[] memory uniswapAmountsOut = IUniswapV2Router02(UNISWAP_ROUTER).getAmountsOut(_inAmount, path);
        uint256[] memory sushiAmountsOut = IUniswapV2Router02(SUSHI_ROUTER).getAmountsOut(_inAmount, path);

        // 按流动性比例从uniswap和sushiswap综合兑换
        uint256 inAmount2Uni = _bBuyToken0 ? _inAmount.mul(uniReserve1).div(uniReserve1.add(suhiReserve1)) 
                                       : _inAmount.mul(uniReserve0).div(uniReserve0.add(suhiReserve0));
        uint256 inAmount2Sushi = _bBuyToken0 ? _inAmount.mul(suhiReserve1).div(uniReserve1.add(suhiReserve1)) 
                                       : _inAmount.mul(suhiReserve0).div(uniReserve0.add(suhiReserve0));

        uint256[] memory uniswapAmountsOutPartOne = IUniswapV2Router02(UNISWAP_ROUTER)
            .getAmountsOut(inAmount2Uni, path);
        uint256[] memory sushiAmountsOutPartTwo = IUniswapV2Router02(SUSHI_ROUTER)
            .getAmountsOut(inAmount2Sushi, path);
        uint256 twoPartsAmount = uniswapAmountsOutPartOne[1] + sushiAmountsOutPartTwo[1];


        if (twoPartsAmount < _minOutAmount && uniswapAmountsOut[1] < _minOutAmount && sushiAmountsOut[1] < _minOutAmount) {
            if (index == 0)
                return (false, new address[](0), new address[](0));
            else
                return (true, bestPath, inAmounts);
        }

        if (twoPartsAmount > uniswapAmountsOut[1] && twoPartsAmount > sushiAmountsOut[1]) {
            bestPath[index] = UNISWAP_ROUTER;
            inAmounts[index] = inAmount2Uni;
            index++;
            bestPath[index] = SUSHI_ROUTER;
            inAmounts[index] = inAmount2Sushi;
            return (true, bestPath, inAmounts);
        } else {
            bestPath[index] = uniswapAmountsOut[1] > sushiAmountsOut[1] ? UNISWAP_ROUTER : SUSHI_ROUTER;
            inAmounts[index] = inAmount;
            return (true, bestPath, inAmounts);
        } 
    }
    
    // 即刻执行交易，可设定执行的次数，此种执行方式不会撮合订单
    function executeInstantly(address _pairAddr, bool _bBuyToken0, uint256 _inAmount, uint256 _minOutAmount, 
                                  CompositeType _compositeType, uint256 _repeatTimes) public returns(uint256 successCount) {
        require(_repeatTimes > 0, "Repeat times must be > 0.");
        address tokenA = pairInfoMap[_pairAddr].tokenA;
        uint256 baseDecimal = 10**(IERC20(tokenA).decimals());
        for (uint i; i < _repeatTimes; i++) {
            uint256 price = IMdexPair(_pairAddr).price(tokenA, baseDecimal);
            bool bExecuted;
            bool bExecutedSuccess;
            (, bExecuted, bExecutedSuccess) = addExecutableOrder(_pairAddr, _bBuyToken0, price, _inAmount, _minOutAmount, _compositeType, Status.Hanging);
            if (!bExecuted) return successCount;
            if (bExecutedSuccess) successCount++;
        }
        return successCount;
    }

    // 添加一个订单，如满足条件，便执行
    function addExecutableOrder(address _pairAddr, bool _bBuyToken0, uint256 _spotPrice, uint256 _inAmount, uint256 _minOutAmount, 
                      CompositeType _compositeType) public returns(uint256 id, bool bExecuted, bool bExecutedSuccess) {
        require(pairList.contains(_pairAddr), "Pair hasn't been exist.");
        Order memory order = addOrder(_pairAddr, _bBuyToken0, _spotPrice, _inAmount, _minOutAmount, _compositeType);
        deposit(order);   // 用户代币已转到本合约
        (bool executable, address[] memory routers, uint256[] memory inAmounts) = evaluateBestSwapPath(order.pairAddr, order.bBuyToken0, order.spotPrice, 
                                                                                         order.inAmount, order.minOutAmount);
        if (executable) {
            for (uint i = 0; i < routers.length; i++) {
                address router = routers[i];
                PairInfo memory pairInfo = pairInfoMap[router];
                if (pairInfo.token0 != address(0) && pairInfo.token1 != address(0)) {

                } else {

                }
            }
        }                                                                              
        bool exeResult = exeOneSwap(order.id);
        return (order.id, true, exeResult);
    }

    function deposit(Order memory order) private {
        address token0 = pairInfoMap[order.pairAddr].token0;
        address token1 = pairInfoMap[order.pairAddr].token1;
        address inTokenAddr = order.bBuyToken0 ? token1 : token0;
        // 将token抵押在本合约中, 需要用户先授权in代币
        IERC20(inTokenAddr).safeTransfer(address(this), order.inAmount);  
        //userTokenAmount[msg.sender][inTokenAddr] = userTokenAmount[msg.sender][inTokenAddr].add(order.inAmount);
    }

    // 撮合订单，当用户以市价成交时，如果有匹配的订单，会调用此接口
    // token1UsedInBook: 消耗在
    function matchOrders(uint256 curOrderId, uint256[] matchedOrderIds, uint256 totalTokenAmountUsedInBook) private {
        Order memory curOrder = orderList[curOrderId];

        address token0 = pairInfoMap[curOrder.pairAddr].token0;
        address token1 = pairInfoMap[curOrder.pairAddr].token1;

        bool bBuyToken0 = curOrder.bBuyToken0;
        uint256 giveOutAmount = 0;
        for (uint256 i = 0; i < matchedOrderIds.length; i++) {
            Order memory matchedOrder = orderList[matchedOrderIds[i]];
            if (bBuyToken0) {  // 当前订单为买单，需要将其U（inAmount）给卖单，卖单把Token0（inAmount）给用户
                if (matchedOrderIds.length - 1 == i) {  // 最后一个匹配的订单，卖家只需要给一部分token0即可
                    uint256 leftAmountOfToken1 = totalTokenAmountUsedInBook.sub(giveOutAmount);    // 卖家剩余的token1
                    IERC20(token1).safeTransfer(matchedOrder.owner, leftAmountOfToken1);  // 将剩余的U给卖家
                    uint256 amountOfToken0 = leftAmountOfToken1.div(matchedOrder.spotPrice);  // 计算出卖家需要给买家的token0数量
                    IERC20(token0).safeTransfer(curOrder.owner, amountOfToken0);  // 将最后一个卖家的部分token0给买家
                } else {   // 从第一个订单到最后倒数第二个订单，卖家需要把所有token0(inAmount)给买家，买家根据收到的token0折算成token1，将token1给卖家
                    IERC20(token1).safeTransfer(curOrder.owner, matchedOrder.inAmount);  // 卖家将所有token0给买家
                    uint256 amountOfToken1 = matchedOrder.inAmount.div(matchedOrder.spotPrice);  // 计算卖家可获得的token1
                    IERC20(token1).safeTransfer(matchedOrder.owner, amountOfToken1);  // 将买家的部分token1给卖家
                }   
            } else {
                if (matchedOrderIds.length - 1 == i) {  // 最后一个匹配的订单，买家只需要给一部分token1即可
                    uint256 leftAmountOfToken1 = totalTokenAmountUsedInBook.sub(giveOutAmount);    // 买家剩余的token0
                    IERC20(token1).safeTransfer(matchedOrder.owner, leftAmountOfToken1);  // 将剩余的U给卖家
                    uint256 amountOfToken0 = leftAmountOfToken1.div(matchedOrder.spotPrice);  // 计算出卖家需要给买家的token0数量
                    IERC20(token0).safeTransfer(curOrder.owner, amountOfToken0);  // 将最后一个卖家的部分token0给买家
                } else {   // 从第一个订单到最后倒数第二个订单，卖家需要把所有token0(inAmount)给买家，买家根据收到的token0折算成token1，将token1给卖家
                    IERC20(token1).safeTransfer(curOrder.owner, matchedOrder.inAmount);  // 卖家将所有token0给买家
                    uint256 amountOfToken1 = matchedOrder.inAmount.div(matchedOrder.spotPrice);  // 计算卖家可获得的token1
                    IERC20(token1).safeTransfer(matchedOrder.owner, amountOfToken1);  // 将买家的部分token1给卖家
                }   
            }
        }
    }

    // 撮合订单
    function matchOrder(uint256 curOrderId, uint256 matchedOrderId) private {
        Order memory curOrder = orderList[curOrderId];
        Order memory matchedOrder = orderList[matchedOrderId];

        address token0 = IMdexPair(order.pairAddr).token0();
        address token1 = IMdexPair(order.pairAddr).token1();
        uint256 decimalsToken0 = IERC20(token0).decimals();
        uint256 decimalsToken1 = IERC20(token1).decimals();

        bool existOfSale;
        uint256 indexOfSale;
        (existOfSale, indexOfSale) = getHeaderOrderIndex(order.pairAddr, false);   // get the first node of the sale list

        bool existOfBuy;
        uint256 indexOfBuy;
        (existOfBuy, indexOfBuy) = getHeaderOrderIndex(order.pairAddr, true);   // get the first node of the buy list

        uint256 count = 0;
        while (existOfSale && existOfBuy) {
            Order storage hangingSalingOrder = orderList[indexOfSale];
            Order storage hangingBuyingOrder = orderList[indexOfBuy];
            if (hangingSalingOrder.spotPrice > hangingBuyingOrder.spotPrice) 
                break;

            if (order.bBuyToken0) {  // 买单触发订单撮合，价格以卖单为准，
                uint256 matchedPrice = hangingSalingOrder.spotPrice;                       // 最低卖价
                uint256 buyableAmount = hangingBuyingOrder.inAmount.mul(10**decimalsToken0).div(matchedPrice);  // 可以购入的token0数量,inAmount是token1的数量
                if (hangingSalingOrder.inAmount > buyableAmount) {   // 第一个卖单数量大于购买者的需求
                    // (1) 交换买卖双方的token，token都已经事先存入合约中
                    // 注意：如果池中的token被用来做机枪池的话，还需要判断金额是否足够，不够的话需要从机枪池中提取
                    IERC20(token0).safeTransfer(hangingBuyingOrder.owner, buyableAmount);  // 合约将购买的token0转给买家
                    IERC20(token1).safeTransfer(hangingSalingOrder.owner, hangingBuyingOrder.inAmount);  // 合约将买家支付的token1金额转给卖家

                    // (2) 把买家的订单从买单列表中删除
                    popFront(order.pairAddr, true);
                    // (3) 修改卖家可卖的token0数量
                    hangingSalingOrder.inAmount = hangingSalingOrder.inAmount.sub(buyableAmount);
                    // (4) 将成交细节记录下来
                    addOrderDetail(hangingSalingOrder.id, hangingBuyingOrder.id, matchedPrice, buyableAmount);
                } else {  // 第一个卖单数量全给购买者
                    // (1) 交换买卖双方的token，token都已经事先存入合约中
                    IERC20(token0).safeTransfer(hangingBuyingOrder.owner, hangingSalingOrder.inAmount);  // 合约将购买的token0转给买家
                    IERC20(token1).safeTransfer(hangingSalingOrder.owner, hangingSalingOrder.inAmount.mul(matchedPrice));  // 合约将买家支付的token1金额转给卖家

                    // (2) 把卖家的订单从卖单列表中删除
                    popFront(order.pairAddr, false);
                    // (3) 修改买家可买的token1数量
                    hangingBuyingOrder.inAmount = hangingBuyingOrder.inAmount.sub(hangingSalingOrder.inAmount.mul(matchedPrice));
                    if (hangingBuyingOrder.inAmount == 0) {  // 如果买家剩余的token1为0，表示其已经买到了所需的token0，可以从订单列表中删除
                        popFront(order.pairAddr, true);
                    }
                    // (4) 将成交细节记录下来
                    addOrderDetail(hangingSalingOrder.id, hangingBuyingOrder.id, matchedPrice, hangingSalingOrder.inAmount);
                }
            } else {  // 卖单触发订单撮合，价格以买单为准
                uint256 matchedPrice = hangingBuyingOrder.spotPrice;    // 最高买价
                uint256 salableAmount = hangingBuyingOrder.inAmount.mul(10**decimalsToken0).div(matchedPrice);  // 可以购入的token1数量,inAmount是token0的数量
                if (salableAmount > hangingSalingOrder.inAmount) {   // 第一个买单数量大于出售量
                    // (1) 交换买卖双方的token，token都已经事先存入合约中
                    IERC20(token0).safeTransfer(hangingBuyingOrder.owner, hangingSalingOrder.inAmount);  // 合约将出售的token0转给买家
                    IERC20(token1).safeTransfer(hangingSalingOrder.owner, hangingSalingOrder.inAmount.mul(hangingBuyingOrder.spotPrice));  // 合约将买家支付的token0金额转给卖家

                    // (2) 把卖家的订单从卖单列表中删除
                    popFront(order.pairAddr, false);
                    // (3) 修改买家可买的token0数量
                    hangingBuyingOrder.inAmount = hangingBuyingOrder.inAmount.sub(hangingSalingOrder.inAmount);
                    // (4) 将成交细节记录下来
                    addOrderDetail(hangingSalingOrder.id, hangingBuyingOrder.id, matchedPrice, hangingSalingOrder.inAmount);
                } else {  // 第一个买单数量全给出售者
                    // (1) 交换买卖双方的token，token都已经事先存入合约中
                    IERC20(token0).safeTransfer(hangingBuyingOrder.owner, salableAmount);  // 合约将购买的token0转给买家
                    IERC20(token1).safeTransfer(hangingSalingOrder.owner, hangingBuyingOrder.inAmount);  // 合约将买家支付的token1金额转给卖家

                    // (2) 把买家的订单从买单列表中删除
                    popFront(order.pairAddr, true);
                    // (3) 修改卖家可卖的token0数量
                    hangingSalingOrder.inAmount = hangingSalingOrder.inAmount.sub(salableAmount);
                    if (hangingSalingOrder.inAmount == 0) {  // 如果卖家剩余的token0为0，表示其已经卖出了所有的token0，可以从订单列表中删除
                        popFront(order.pairAddr, false);
                    }
                    // (4) 将成交细节记录下来
                    addOrderDetail(hangingSalingOrder.id, hangingBuyingOrder.id, matchedPrice, salableAmount);
                }
            }
            count++;
            (existOfSale, indexOfSale) = getHeaderOrderIndex(order.pairAddr, false);
            (existOfBuy, indexOfBuy) = getHeaderOrderIndex(order.pairAddr, true); 
        }
        return count;
    }
    
    function exeOneSwap(uint256 index) private returns(bool) {
        Order storage order = orderList[index];
        address token0 = pairInfoMap[order.pairAddr].token0;
        address token1 = pairInfoMap[order.pairAddr].token1;
                
        uint256 resultType;
        string memory result; 
        (resultType, result) = checkOrderExecutable(index);
        if (resultType > 0) {
            order.comment = result;
            order.status = Status.Exception;
            return false;
        }
        address inTokenAddr = order.bBuyToken0 ? token1 : token0;
        // 0: 开始交易，需要扣除用户抵押在合约中的token
        // if (userTokenAmount[msg.sender][inTokenAddr] < order.inAmount)
        //     return false;
        // userTokenAmount[msg.sender][inTokenAddr] = userTokenAmount[msg.sender][inTokenAddr].sub(order.inAmount);
        
        // 1：本合约将in代币授权给router合约
        IERC20(inTokenAddr).approve(bestSwapRouter, order.inAmount); 
        // 2：发起挖矿交易 
        address[] memory path = new address[](2);
        (path[0], path[1]) = order.bBuyToken0 ? (token1, token0) : (token0, token1);
        uint256 balanceBefore = IERC20(path[1]).balanceOf(order.owner);
        IMdexRouter(bestSwapRouter).swapExactTokensForTokens(order.inAmount, order.minOutAmount, path, order.owner, block.timestamp);  
        order.outAmount = IERC20(path[1]).balanceOf(order.owner).sub(balanceBefore);
        // 3: 提取或卖出MDX
        if (order.compositeType == CompositeType.SwapClaim || order.compositeType == CompositeType.SwapClaimWithdraw) {
            uint mdxBeforeWithdraw = IERC20(MDX).balanceOf(address(this));
            ISwapMining(MDX_SWAP_MINING).takerWithdraw();  // 提取 MDX 到本合约
            uint mdxAfterWithdraw = IERC20(MDX).balanceOf(address(this));
            uint minedMdx = mdxAfterWithdraw.sub(mdxBeforeWithdraw);
            // 4：根据用户设定，卖出挖矿的MDX 或 将MDX直接转给用户
            if (order.compositeType == CompositeType.SwapClaimWithdraw) {  // 将MDX换成USDT
                swapMdx2USDT(minedMdx, order.owner);
            } else {
                IERC20(MDX).safeTransfer(order.owner, minedMdx);
            }
        }
        order.status = Status.DoneByAMM;
        order.exeTime = block.timestamp;
        order.exchangeObject = order.pairAddr;
        return true;
    } 

    // 检查一个交易当前是否可执行
    function checkOrderExecutable(uint256 index) view public returns(uint256 resultType, string memory result) {
        Order memory order = orderList[index];
        
        address token0 = pairInfoMap[order.pairAddr].token0;
        address token1 = pairInfoMap[order.pairAddr].token1;
        
        address inTokenAddr = order.bBuyToken0 ? token1 : token0;
        
        // 检查授权条件（无需检查，因为用户资金已经转入本合约）
        // uint256 approvedAmount = IERC20(inTokenAddr).allowance(order.owner, address(this));
        // if (approvedAmount < order.inAmount) {
        //     result = "Approved amount is not enough.";
        //     return (1, result);
        // }
        
        // 检查订单价格是否满足AMM池子中的交易价
        // uint256 baseDecimal = 10**(IERC20(token0).decimals());
        // uint256 price = IMdexPair(order.pairAddr).price(token0, baseDecimal);   // calculate the price of token0, token1 per token0
        // if ((order.bBuyToken0 && price > order.spotPrice) || (!order.bBuyToken0 && price < order.spotPrice)) {
        //     result = "Price doesn't reach the spoted value.";
        //     return (3, result);
        // }
        // // 检查从AMM中置换出的token数量是否满足最小量
        // (uint256 reserve0, uint256 reserve1,) = IMdexPair(order.pairAddr).getReserves();  // 
        // uint256 amountOut = IMdexRouter(bestSwapRouter).getAmountOut(order.inAmount, order.bBuyToken0 ? reserve1 : reserve0, order.bBuyToken0 ? reserve0 : reserve1);
        // if (amountOut < order.minOutAmount) {
        //     result = "Amount out is less than expected amount.";
        //     return (4, result);
        // }


        (bool executable, address[] memory routers, uint256[] memory inAmounts) = evaluateBestSwapPath(order.pairAddr, order.bBuyToken0, order.spotPrice, 
                                                                                         order.inAmount, order.minOutAmount);
        return (0, "");
    }

    // 获取满足交易条件的交易对 
    // check whether there is more than one order to satisfy the condition of swapping
    function getAllSwapablePairs() view public returns(address[] memory _pairAddrList) {
        address[] memory pairAddrList = new address[](pairList.length());  // 当地址为0时，即结束
        uint256 count = 0;
        uint256 pairLength = pairList.length();
        for (uint256 i = 0; i < pairLength; i++) {
            address pairAddr = pairList.at(i);
            
            address token0 = IMdexPair(pairAddr).token0();
            uint256 baseDecimal = 10**(IERC20(token0).decimals());
            uint256 curPrice = IMdexPair(pairAddr).price(token0, baseDecimal);   // calculate the price of token0, token1 per token0
            
            bool existOfBuy;
            uint256 indexOfBuy;
            (existOfBuy, indexOfBuy) = getHeaderOrderIndex(pairAddr, true);   // get the first node of the list
            
            bool existOfSale;
            uint256 indexOfSale;
            (existOfSale, indexOfSale) = getHeaderOrderIndex(pairAddr, false);   // get the first node of the list
            
            if (existOfBuy) {
                uint256 lowPrice = orderList[indexOfBuy - 1].spotPrice;
                if (curPrice <= lowPrice) {
                    pairAddrList[count++] = pairAddr;
                } else if (existOfSale) {
                    uint256 upPrice = orderList[indexOfSale - 1].spotPrice;
                    if (curPrice >= upPrice) {
                        pairAddrList[count++] = pairAddr;
                    }
                }
            }
        }
        return pairAddrList;
    }

    // 
    function batchSwap(address pairAddr) public returns (uint256[] memory executedOrderList, bool[] memory executedOrderResults) {
        executedOrderList = new uint256[](maxNumberPerSwap);
        executedOrderResults = new bool[](maxNumberPerSwap);
        
        address token0 = IMdexPair(pairAddr).token0();
        uint256 baseDecimal = 10**(IERC20(token0).decimals());
        uint256 curPrice = IMdexPair(pairAddr).price(token0, baseDecimal);   // calculate the price of token0, token1 per token0
        
        bool existOfBuy;
        uint256 indexOfBuy;
        (existOfBuy, indexOfBuy) = getHeaderOrderIndex(pairAddr, true);   // get the first node of the list
        
        bool existOfSale;
        uint256 indexOfSale;
        (existOfSale, indexOfSale) = getHeaderOrderIndex(pairAddr, false);  // get the first node of the list
        
        uint256 lowPrice = existOfBuy ? orderList[indexOfBuy - 1].spotPrice : 0;
        uint256 upPrice = existOfSale ? orderList[indexOfSale - 1].spotPrice : (uint256(-1));
        
        if (curPrice <= lowPrice) {  
            (executedOrderList, executedOrderResults) = processOnePairOrders(curPrice, pairAddr, true);
        } else if (curPrice >= upPrice) {
            (executedOrderList, executedOrderResults) = processOnePairOrders(curPrice, pairAddr, false);
        }
        return (executedOrderList, executedOrderResults);
    }
    
    function processOnePairOrders(uint256 curPrice, address pairAddr, bool bBuy) private returns(uint256[] memory, bool[] memory) {
        uint256 maxNumberPerSwap = IExchangeManager(EX_Manager).maxNumberPerAMMSwap();
        uint256[] memory executedOrderList = new uint256[](maxNumberPerSwap);
        bool[] memory executedOrderResults = new bool[](maxNumberPerSwap);
        
        uint256 count = 0;
        uint256 index = popFront(pairAddr, bBuy);
        while (index > 0) {
            Order memory order = orderList[index - 1];
            if ((bBuy && order.spotPrice >= curPrice) || (!bBuy && order.spotPrice <= curPrice)) {
                bool result = exeOneSwap(index - 1);
                executedOrderList[count++] = index - 1;
                executedOrderResults[count++] = result;
                if (count == maxNumberPerSwap) break;
            } else {
                pushFront(pairAddr, bBuy, index);
                break;
            }
            index = popFront(pairAddr, bBuy);
        }
        return (executedOrderList, executedOrderResults);
    }

    function cancelOrder(uint256 orderId) public returns(bool) {
        manualCancelOrder(orderId);

        Order memory order = orderList[index];
        
        address token0 = IMdexPair(order.pairAddr).token0();
        address token1 = IMdexPair(order.pairAddr).token1();
        
        address inTokenAddr = order.bBuyToken0 ? token1 : token0;
        IERC20(inTokenAddr).safeTransfer(msg.sender, order.inAmount);  
    }
}