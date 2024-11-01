// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract RCCStake is
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;

    //*************************** INVARIANTS ***************************
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADE_ROLE = keccak256("UPGRADE_ROLE");

    uint256 public constant nativeCurrency_PID = 0;

    //*************************** DATA STRUCTURE ***************************
    struct Pool {
        //质押代币的地址
        address stTokenAddress;
        //质押池的权重，影响奖励分配
        uint256 poolWeight;
        //最后一次计算奖励的区块号
        uint256 lastRewordBlock;
        //每个质押代币累积的 RCC 数量
        uint256 accRCCPerST;
        //池中的总质押代币量
        uint256 stTokenAmount;
        //最小质押数量
        uint256 minDepositAmount;
        //解除质押的锁定区块数
        uint256 unstakeLockedBlocks;
    }

    struct UnstakeRequest {
        //解质押数量
        uint256 amount;
        //解锁区块
        uint256 unlockBlocks;
    }

    struct User {
        //用户质押的代币数量
        uint256 stAmount;
        //已分配的 RCC 数量
        uint256 finishedRCC;
        //待领取的 RCC 数量
        uint256 pendingRCC;
        //解质押请求列表，每个请求包含解质押数量和解锁区块
        UnstakeRequest[] requests;
    }

    //**********************************************STAT VARIABLES ***************************
    //质押开始的区块号
    uint256 public startBlock;
    //质押结束的区块号
    uint256 public endBlock;
    //每个区块的奖励
    uint256 public RCCPerBlock;

    //暂停提币
    bool public withdrawPaused;
    //暂停索赔
    bool public claimPaused;

    //RCC token
    IERC20 public RCC;

    //质押池总权重
    uint256 public totalPoolWeight;
    //质押池
    Pool[] public pool;
    //质押用户信息  poolId => （user address => user)
    mapping(uint256 => mapping(address => User)) public user;

    //********************************************** EVENT ***************************
    //设置奖励token合约
    event SetRcc(IERC20 indexed RCC);

    //暂停提币
    event PauseWithdraw();
    //恢复提币
    event UnPauseWithdraw();

    //暂停索赔
    event PauseClaim();
    //恢复索赔
    event UnPauseClaim();

    //设置起始块号
    event SetStartBlock(uint256 indexed startBlock);

    //设置结束块号
    event SetEndBlock(uint256 indexed endBlock);

    //设置每个块奖励的RCC数量
    event SetRCCPerBlock(uint256 indexed RCCPerBlock);

    //添加质押池
    event AddPool(
        address indexed stTokenAddress,
        uint256 indexed poolWeight,
        uint256 indexed lastRewardBlock,
        uint256 minDepositAmount,
        uint256 unstatkeLockedBlock
    );

    //更新质押池 最小质押数、解除质押的锁定区块数
    event UpdatePoolInfo(
        uint256 indexed poolId,
        uint256 indexed minDepositAmount,
        uint256 indexed unstatkeLockedBlock
    );

    //设置质押池
    event SetPoolWight(
        uint256 indexed poolId,
        address indexed poolWeight,
        uint256 indexed totalPoolWeight
    );

    //更新质押池
    event UpdatePool(
        uint256 indexed poolId,
        uint256 indexed lastRewordBlock,
        uint256 totalRCC
    );

    //抵押
    event Deposit(address indexed user, uint256 indexed poolId, uint256 amount);

    //解除质押
    event RequestUnStake(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount
    );

    //提币
    event Withdraw(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount,
        uint256 indexed blockNumber
    );

    //索赔
    event Claim(address indexed user, uint256 indexed poolId, uint256 RCCRward);

    //********************************************** MODIFIER ***************************
    //质押池id有效性判断
    modifier checkPid(uint256 _pid) {
        require(_pid < pool.length, "invalid pid");
        _;
    }

    //索赔开启
    modifier whenNotClaimPaused() {
        require(!claimPaused, "claim is paused");
        _;
    }

    //提现开启
    modifier whenNotWithdrawPaused() {
        require(!withdrawPaused, "withdraw is paused");
        _;
    }
    //_RCC = 0x8B901A752B374D26aFddd2c4b57334Fd51693EeA
    function initialize(
        IERC20 _RCC,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _RCCPerBlock
    ) public initializer {
        require(_startBlock < _endBlock && _RCCPerBlock > 0, "invalid params");
        //初始化访问控制
        __AccessControl_init();
        //初始化可升级方法
        __UUPSUpgradeable_init();
        //授权
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADE_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        //设置代币
        setRCC(_RCC);

        startBlock = _startBlock;
        endBlock = _endBlock;
        RCCPerBlock = _RCCPerBlock;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADE_ROLE) {}

    //********************************************** ADMIN FUNCTION ***************************
    /**
     *   设置RCC token 地址
     */
    function setRCC(IERC20 _RCC) public onlyRole(ADMIN_ROLE) {
        RCC = _RCC;
        emit SetRcc(_RCC);
    }

    function pauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(!withdrawPaused, "withdraw has been already paused");

        withdrawPaused = true;
        emit PauseWithdraw();
    }

    function unPauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(withdrawPaused, "withdraw has been already unpaused");

        withdrawPaused = false;
        emit UnPauseWithdraw();
    }

    function pauseClaim() public onlyRole(ADMIN_ROLE) {
        require(!claimPaused, "claim has been already paused");
        claimPaused = true;
        emit PauseClaim();
    }

    function unPauseClaim() public onlyRole(ADMIN_ROLE) {
        require(claimPaused, "claim has been already unpaused");
        claimPaused = false;
        emit UnPauseClaim();
    }

    function setStartBlock(uint256 _startBlock) public onlyRole(ADMIN_ROLE) {
        require(
            _startBlock <= endBlock,
            "start block must be smaller than end block"
        );
        startBlock = _startBlock;
        emit SetStartBlock(_startBlock);
    }

    function setEndBlock(uint256 _endBlock) public onlyRole(ADMIN_ROLE) {
        require(
            startBlock <= _endBlock,
            "end block must be bigger than end block"
        );
        endBlock = _endBlock;
        emit SetEndBlock(_endBlock);
    }

    function setRCCPerBlock(uint256 _RCCPerBlock) public onlyRole(ADMIN_ROLE) {
        require(_RCCPerBlock > 0, "invalid parameter");
        RCCPerBlock = _RCCPerBlock;
        emit SetRCCPerBlock(_RCCPerBlock);
    }

    /// 添加质押池
    /// @param _stTokenAddress 质押币合约地址
    /// @param _poolWeight 质押权重
    /// @param _minDepositAmount 最小质押数量
    /// @param _unStakeLockedBlocks 解除质押锁定区块数
    /// @param _withUpdate 是否更新
    function addPool(
        address _stTokenAddress,
        uint256 _poolWeight,
        uint256 _minDepositAmount,
        uint256 _unStakeLockedBlocks,
        bool _withUpdate
    ) public onlyRole(ADMIN_ROLE) {
        if (pool.length > 0) {
            require(
                _stTokenAddress != address(0x0),
                "invalid staking token address"
            );
        } else {
            require(
                _stTokenAddress == address(0x0),
                "invalid staking token address"
            );
        }
        require(_unStakeLockedBlocks > 0, "invalid min deposit amount");

        require(block.number < endBlock, "Already ended");

        if (_withUpdate) {
            //更新
            massUpdatePools();
        }

        uint256 lastRewordBlock = block.number > startBlock
            ? block.number
            : startBlock;

        totalPoolWeight = totalPoolWeight + _poolWeight;
        pool.push(
            Pool({
                stTokenAddress: _stTokenAddress,
                poolWeight: _poolWeight,
                lastRewordBlock: lastRewordBlock,
                accRCCPerST: 0,
                stTokenAmount: 0,
                minDepositAmount: _minDepositAmount,
                unstakeLockedBlocks: _unStakeLockedBlocks
            })
        );

        emit AddPool(
            _stTokenAddress,
            _poolWeight,
            lastRewordBlock,
            _minDepositAmount,
            _unStakeLockedBlocks
        );
    }

    function updatePool(
        uint256 _pid,
        uint256 _minDepositAmount,
        uint256 _unstakeLockedBlocks
    ) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        pool[_pid].minDepositAmount = _minDepositAmount;
        pool[_pid].unstakeLockedBlocks = _unstakeLockedBlocks;
    }

    function setPoolWeight(
        uint256 _pid,
        uint256 _poolWeight,
        bool _withUpdate
    ) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        require(_poolWeight > 0, "invalid pool weight");
        if (_withUpdate) {
            //更新
            massUpdatePools();
        }

        totalPoolWeight = totalPoolWeight - pool[_pid].poolWeight + _poolWeight;
        pool[_pid].poolWeight = _poolWeight;
    }

    //********************************************** QUERY FUNCTION ***************************

    function poolLength() external view returns (uint256) {
        return pool.length;
    }

    /// 计算奖励
    /// @param _from 开始块
    /// @param _to 结束块
    function getMultiplier(
        uint256 _from,
        uint256 _to
    ) public view returns (uint256 multiplier) {
        require(_to >= _from, "invalid block range");
        if (_from < startBlock) {
            _from = startBlock;
        }

        if (_to >= endBlock) {
            _to = endBlock;
        }

        require(_from < _to, "end block must be greater than start block");
        bool success;
        (success, multiplier) = (_to - _from).tryMul(RCCPerBlock);
        require(success, "multiplier overflow");
    }

    function pendingRCC(
        uint256 _pid,
        address _user
    ) external view checkPid(_pid) returns (uint256) {
        return pendingRCCByBlockNumber(_pid, _user, block.number);
    }

    /// 获取用户的待领取收益
    /// @param _pid 质押池id
    /// @param _user 用户
    /// @param _blockNumber 块号
    function pendingRCCByBlockNumber(
        uint256 _pid,
        address _user,
        uint256 _blockNumber
    ) public view checkPid(_pid) returns (uint256) {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][_user];
        uint256 accRccPerST = pool_.accRCCPerST;
        uint256 stSupply = pool_.stTokenAmount;

        if (_blockNumber > pool_.lastRewordBlock && stSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool_.lastRewordBlock,
                _blockNumber
            );
            uint256 RCCForPool = (multiplier * pool_.poolWeight) /
                totalPoolWeight;
            accRccPerST = accRccPerST + (RCCForPool * (1 ether)) / stSupply;
        }

        return
            (user_.stAmount * accRccPerST) /
            (1 ether) -
            user_.finishedRCC +
            user_.pendingRCC;
    }

    function stakingBalance(
        uint256 _pid,
        address _user
    ) external view checkPid(_pid) returns (uint256) {
        return user[_pid][_user].stAmount;
    }

    function withdrawAmount(
        uint256 _pid,
        address _user
    )
        public
        view
        checkPid(_pid)
        returns (uint256 requestAmount, uint256 pendingWithdrawAmount)
    {
        User storage user_ = user[_pid][_user];
        for (uint256 i = 0; i < user_.requests.length; i++) {
            //解除质押到期
            if (user_.requests[i].unlockBlocks <= block.number) {
                pendingWithdrawAmount =
                    pendingWithdrawAmount +
                    user_.requests[i].amount;
            }
            requestAmount = requestAmount + user_.requests[i].amount;
        }
    }

    //********************************************** PUBLIC FUNCTION ***************************

    function updatePool(uint256 _pid) public checkPid(_pid) {
        Pool storage pool_ = pool[_pid];
        if (block.number <= pool_.lastRewordBlock) {
            return;
        }

        (bool success1, uint256 totalRCC) = getMultiplier(
            pool_.lastRewordBlock,
            block.number
        ).tryMul(pool_.poolWeight);
        require(success1, "totalRCC mul poolWeight overflow");

        (success1, totalRCC) = totalRCC.tryDiv(totalPoolWeight);
        require(success1, "totalRCC div totalPoolWeight overflow");

        uint256 stSupply = pool_.stTokenAmount;
        if (stSupply > 0) {
            //单位从eth 换成 wei
            (bool success2, uint256 totalRCC_) = totalRCC.tryMul(1 ether);
            require(success2, "totalRCC_ mul 1 ether overflow");

            (success2, totalRCC_) = totalRCC_.tryDiv(stSupply);
            require(success2, "totalRCC div stSupply overflow");

            (bool success3, uint256 accRCCPerST) = pool_.accRCCPerST.tryAdd(
                totalRCC_
            );
            require(success3, "pool accRCCPerST overflow");
            pool_.accRCCPerST = accRCCPerST;
        }
        pool_.lastRewordBlock = block.number;
        emit UpdatePool(_pid, pool_.lastRewordBlock, totalRCC);
    }

    function massUpdatePools() public {
        uint256 length = pool.length;
        for (uint256 i = 0; i < length; i++) {
            updatePool(i);
        }
    }

    function depositNativeCurrency() public payable whenNotPaused {
        Pool storage pool_ = pool[nativeCurrency_PID];
        require(
            pool_.stTokenAddress == address(0x0),
            "invalid staking token address"
        );

        uint256 _amount = msg.value;

        require(
            _amount >= pool_.minDepositAmount,
            "deposit amount is too small"
        );
        _deposit(nativeCurrency_PID, _amount);
    }

    function depoist(
        uint256 _pid,
        uint256 _amount
    ) public whenNotPaused checkPid(_pid) {
        require(_pid != 0, "deposit not support nativeCurrency staking");
        Pool storage pool_ = pool[_pid];
        require(
            _amount > pool_.minDepositAmount,
            "depoist amount is too small"
        );
        if (_amount > 0) {
            IERC20(pool_.stTokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
        }

        _deposit(_pid, _amount);
    }

    function _deposit(uint256 _pid, uint256 _amount) internal {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];
        updatePool(_pid);
        if (user_.stAmount > 0) {
            (bool success1, uint256 accST) = user_.stAmount.tryMul(
                pool_.accRCCPerST
            );
            require(success1, "user stAmount mul accRCCPerST overflow");
            (success1, accST) = accST.tryDiv(1 ether);
            require(success1, "accST div 1 ether overflow");
            (bool success2, uint256 pendingRCC_) = accST.trySub(
                user_.finishedRCC
            );
            require(success2, "accST sub finishedRCC overflow");

            if (pendingRCC_ > 0) {
                (bool success3, uint256 _pendingRCC) = user_.pendingRCC.tryAdd(
                    pendingRCC_
                );
                require(success3, "user pendingRCC overflow");
                user_.pendingRCC = _pendingRCC;
            }

            if (_amount > 0) {
                (bool success4, uint256 stAmount) = user_.stAmount.tryAdd(
                    _amount
                );
                require(success4, "user stAmount overflow");
                user_.stAmount = stAmount;
            }

            (bool success5, uint256 stTokenAmount) = pool_.stTokenAmount.tryAdd(
                _amount
            );
            require(success5, "pool stTokenAmount overflow");
            pool_.stTokenAmount = stTokenAmount;

            (bool success6, uint256 finishedRCC) = user_.stAmount.tryMul(
                pool_.accRCCPerST
            );
            require(success6, "user stAmount mul accRCCPerST overflow");

            (success6, finishedRCC) = finishedRCC.tryDiv(1 ether);
            require(success6, "finishedRCC div 1 ether overflow");

            user_.finishedRCC = finishedRCC;

            emit Deposit(msg.sender, _pid, _amount);
        }
    }

    function unstake(
        uint256 _pid,
        uint256 _amount
    ) public whenNotPaused checkPid(_pid) {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];
        require(user_.stAmount >= _amount, "insufficient stAmount");
        updatePool(_pid);
        (bool success1, uint256 accST) = user_.stAmount.tryMul(
            pool_.accRCCPerST
        );
        require(success1, "user stAmount mul accRCCPerST overflow");
        (success1, accST) = accST.tryDiv(1 ether);
        require(success1, "accST div 1 ether overflow");
        (bool success2, uint256 pendingRCC_) = accST.trySub(user_.finishedRCC);
        require(success2, "accST sub finishedRCC overflow");

        if (pendingRCC_ > 0) {
            (bool success3, uint256 _pendingRCC) = user_.pendingRCC.tryAdd(
                pendingRCC_
            );
            require(success3, "user pendingRCC overflow");
            user_.pendingRCC = _pendingRCC;
        }
        if (_amount > 0) {
            user_.stAmount = user_.stAmount - _amount;
            user_.requests.push(
                UnstakeRequest({
                    amount: _amount,
                    unlockBlocks: block.number + pool_.unstakeLockedBlocks
                })
            );
        }

        pool_.stTokenAmount = pool_.stTokenAmount - _amount;
        user_.finishedRCC = (user_.stAmount * pool_.accRCCPerST) / (1 ether);

        emit RequestUnStake(msg.sender, _pid, _amount);
    }

    function withdraw(
        uint256 _pid
    ) public whenNotPaused checkPid(_pid) whenNotWithdrawPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];
        uint256 pendingWithdraw_;
        uint256 popNum_;

        for (uint256 i = 0; i < user_.requests.length; i++) {
            //由于请求列表是顺序的，遍历到块号超过当前块，说明后面已经不能解锁了
            if (user_.requests[i].unlockBlocks > block.number) {
                break;
            }
            pendingWithdraw_ = pendingWithdraw_ + user_.requests[i].amount;
            popNum_++;
        }
        //将块前移
        for (uint256 i = 0; i < user_.requests.length - popNum_; i++) {
            user_.requests[i] = user_.requests[i + popNum_];
        }

        //将空块移除
        for (uint256 i = 0; i < popNum_; i++) {
            user_.requests.pop();
        }

        if (pendingWithdraw_ > 0) {
            if (pool_.stTokenAddress == address(0x0)) {
                _safenativeCurrencyTransfer(msg.sender, pendingWithdraw_);
            } else {
                IERC20(pool_.stTokenAddress).safeTransfer(
                    msg.sender,
                    pendingWithdraw_
                );
            }
        }

        emit Withdraw(msg.sender, _pid, pendingWithdraw_, block.number);
    }

    function claim(
        uint256 _pid
    ) public whenNotPaused checkPid(_pid) whenNotClaimPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];
        updatePool(_pid);
        uint256 pendingRCC_ = (user_.stAmount * pool_.accRCCPerST) /
            (1 ether) -
            user_.finishedRCC +
            user_.pendingRCC;
        if (pendingRCC_ > 0) {
            user_.pendingRCC = 0;
            _safeRCCTransfer(msg.sender, pendingRCC_);
        }
        user_.finishedRCC = (user_.stAmount * pool_.accRCCPerST) / (1 ether);
        emit Claim(msg.sender, _pid, pendingRCC_);
    }

    // 内部函数，用于安全地转移原生货币
    function _safenativeCurrencyTransfer(
        address _to,
        uint256 _amount
    ) internal {
        // 调用_to地址的call函数，发送_amount数量的原生货币
        (bool success, bytes memory data) = address(_to).call{value: _amount}(
            ""
        );
        // 检查转账是否成功
        require(success, "nativeCurrency transfer failed");

        // 如果返回的数据长度大于0
        if (data.length > 0) {
            // 解码返回的数据，检查转账是否成功
            require(
                abi.decode(data, (bool)),
                "nativeCurrency  transfer failed"
            );
        }
    }

    function _safeRCCTransfer(address _to, uint256 _amount) internal {
        uint256 RCCBal = RCC.balanceOf(address(this));
        require(RCCBal >= _amount, "ERC20: transfer amount exceeds balance");
        RCC.safeTransfer(_to, _amount);
    }
}
