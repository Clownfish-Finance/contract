const { expect } = require("chai");
const hre = require("hardhat");
const {
  loadFixture,
  time,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const AP_ACCOUNT_FACTORY = "ACCOUNT_FACTORY";

const ICreditFacadeMulticallABI = [
  "function addCollateral(address token, uint256 amount) external",
];

// const ILendingPoolABI = [
//     "function deposit(address asset, uint256 amount, address onBehalfOf) external"
// ]

function setupEventListeners({
  creditFacade,
  accountFactory,
  underlyingToken,
  pool,
  creditManager,
}) {
  // accountFactory
  accountFactory.on(
    "AddCreditManager",
    (creditManager, masterCreditAccount) => {
      console.log("===AddCreditManager===");
      console.log("creditManager", creditManager);
      console.log("masterCreditAccount", masterCreditAccount);
    }
  );

  accountFactory.on("TakeCreditAccount", (creditAccount, creditManager) => {
    console.log("===TakeCreditAccount===");
    console.log("creditAccount", creditAccount);
    console.log("creditManager", creditManager);
  });

  accountFactory.on("DeployCreditAccount", (creditAccount, creditManager) => {
    console.log("===DeployCreditAccount===");
    console.log("creditAccount", creditAccount);
    console.log("creditManager", creditManager);
  });

  //   pool
  pool.on("Borrow", (creditManager, creditAccount, amount) => {
    console.log("===Borrow===");
    console.log("creditManager", creditManager);
    console.log("creditAccount", creditAccount);
    console.log("amount", hre.ethers.formatEther(amount));
  });

  pool.on("Deposit", (caller, receiver, assets, shares) => {
    console.log("===Deposit===");
    console.log("caller", caller);
    console.log("receiver", receiver);
    console.log("assets", hre.ethers.formatEther(assets));
    console.log("shares", hre.ethers.formatEther(shares));
  });
  // creditFacade
  creditFacade.on("StartMultiCall", (creditAccount, caller) => {
    console.log("===StartMultiCall===");
    console.log("creditAccount", creditAccount);
    console.log("caller", caller);
  });

  creditFacade.on("OpenCreditAccount", (creditAccount, onBehalfOf, caller) => {
    console.log("===OpenCreditAccount===");
    console.log("creditAccount", creditAccount);
    console.log("onBehalfOf", onBehalfOf);
    console.log("caller", caller);
  });

  creditFacade.on("IncreaseCredit", (creditAccount, amount) => {
    console.log("===IncreaseCredit===");
    console.log("creditAccount", creditAccount);
  });

  creditFacade.on("IncreaseDebt", (creditAccount, amount) => {
    console.log("===IncreaseDebt===");
    console.log("creditAccount", creditAccount);
    console.log("amount", hre.ethers.formatEther(amount));
  });

  creditFacade.on("AddCollateral", (creditAccount, token, amount) => {
    console.log("===AddCollateral===");
    console.log("creditAccount", creditAccount);
    console.log("token", token);
    console.log("amount", amount);
  });

  creditFacade.on("Execute", (creditAccount, targetContract) => {
    console.log("===Execute===");
    console.log("creditAccount", creditAccount);
    console.log("targetContract", targetContract);
  });
}

describe("Test", function () {
  async function deploy() {
    const linearInterestRateModel = await hre.ethers.deployContract(
      "LinearInterestRateModel",
      [
        5000, // U_1 (in basis points, e.g., 50%)
        8000, // U_2 (in basis points, e.g., 80%)
        200, // R_base (in basis points, e.g., 2%)
        400, // R_slope1 (in basis points, e.g., 4%)
        800, // R_slope2 (in basis points, e.g., 8%)
        1500, // R_slope3 (in basis points, e.g., 15%)
        true, // isBorrowingMoreU2Forbidden (whether to prevent borrowing over U_2 utilization)
      ]
    );

    const addressProvider = await hre.ethers.deployContract("AddressProvider");
    const accountFactory = await hre.ethers.deployContract("AccountFactory");
    const key = hre.ethers.encodeBytes32String(AP_ACCOUNT_FACTORY);
    await addressProvider.setAddress(key, accountFactory.target);

    const underlyingToken = await hre.ethers.deployContract("UnderlyingToken");
    const pool = await hre.ethers.deployContract("Pool", [
      addressProvider.target,
      underlyingToken.target,
      linearInterestRateModel.target,
      hre.ethers.parseEther("1000"),
      "pool_token",
      "pool_token_symbol",
    ]);
    const creditManager = await hre.ethers.deployContract("CreditManager", [
      addressProvider.target,
      pool.target,
    ]);
    const creditFacade = await hre.ethers.deployContract("CreditFacade", [
      creditManager.target,
    ]);

    // adapter
    const lendingPoolMock = await hre.ethers.deployContract("LendingPoolMock");
    const lendingPoolAdapter = await hre.ethers.deployContract(
      "AaveV2_LendingPoolAdapter",
      [creditManager, lendingPoolMock]
    );

    // initialize
    await creditManager.setCreditFacade(creditFacade.target);
    await accountFactory.addCreditManager(creditManager.target);
    await pool.setCreditManagerDebtLimit(
      creditManager.target,
      hre.ethers.parseEther("1000")
    );
    const debtLimit = await pool.creditManagerDebtLimit(creditManager.target);
    const totalDebtLimit = await pool.totalDebtLimit();
    console.log("debtLimit", hre.ethers.formatEther(debtLimit));
    console.log("totalDebtLimit", hre.ethers.formatEther(totalDebtLimit));

    const [account1, account2] = await hre.ethers.getSigners();

    const iCreditFacadeMulticall = new hre.ethers.Interface(
      ICreditFacadeMulticallABI
    );

    //adapter initialize
    await creditManager.setContractAllowance(
      lendingPoolAdapter.target,
      lendingPoolMock.target
    );
    await lendingPoolMock.addReserve(
      underlyingToken.target,
      BigInt("20000000000000000000000000")
    );
    const reserveData = await lendingPoolMock.getReserveData(
      underlyingToken.target
    );
    const aTokenAddr = reserveData.aTokenAddress;
    await creditManager.addToken(aTokenAddr);

    // log address
    console.log("account1", account1.address);
    console.log("account2", account2.address);
    // log contract address
    console.log("creditFacade", creditFacade.target);
    console.log("creditManager", creditManager.target);
    console.log("accountFactory", accountFactory.target);
    console.log("pool", pool.target);
    console.log("underlyingToken", underlyingToken.target);
    // log adapter address
    console.log("lendingPoolAdapter", lendingPoolAdapter.target);
    console.log("lendingPoolMock", lendingPoolMock.target);
    console.log("aToken address", aTokenAddr);

    setupEventListeners({
      creditFacade,
      accountFactory,
      underlyingToken,
      pool,
      creditManager,
    });

    return {
      creditFacade,
      accountFactory,
      underlyingToken,
      pool,
      creditManager,
      iCreditFacadeMulticall,
      account1,
      account2,
      lendingPoolAdapter,
      lendingPoolMock,
      aTokenAddr,
    };
  }

  it("adapter deposit", async function () {
    const {
      creditFacade,
      underlyingToken,
      creditManager,
      iCreditFacadeMulticall,
      account1,
      lendingPoolAdapter,
      lendingPoolMock,
      aTokenAddr,
    } = await loadFixture(deploy);
    let creditAccount1;
    const aToken = await hre.ethers.getContractAt("ATokenMock", aTokenAddr);
    // get credit account
    await creditFacade.openCreditAccount(account1, []);
    creditFacade.on(
      "OpenCreditAccount",
      (creditAccount, onBehalfOf, caller) => {
        creditAccount1 = creditAccount;
        console.log("set creditAccount1", creditAccount1);
      }
    );
    await delay(2000);
    // mint 100 eth underlying token on account1 and deposit 50 eth underlying token to creditAccount1
    const initMintAmount = hre.ethers.parseEther("100");
    await underlyingToken.mint(account1.address, initMintAmount);
    await underlyingToken.approve(creditManager.target, initMintAmount);
    const addCollateralEncode = iCreditFacadeMulticall.encodeFunctionData(
      "addCollateral",
      [underlyingToken.target, initMintAmount / 2n]
    );
    const addCollateralCallData = [
      {
        target: creditFacade,
        callData: addCollateralEncode,
      },
    ];
    console.log("=== add collateral ===");
    console.log("creditAccount1", creditAccount1);
    console.log("addCollateralCallData", addCollateralCallData);
    await creditFacade.multicall(creditAccount1, addCollateralCallData);
    await delay(1000);
    // build encode data for deposit
    // function deposit(address asset, uint256 amount) external returns (uint256 tokensToEnable, uint256 tokensToDisable);
    const depositEncode = lendingPoolAdapter.interface.encodeFunctionData(
      "deposit",
      [underlyingToken.target, hre.ethers.parseEther("10")]
    );
    const depositCallData = [
      {
        target: lendingPoolAdapter,
        callData: depositEncode,
      },
    ];
    await creditFacade.multicall(creditAccount1, depositCallData);
    await delay(1000);

    console.log("=== print balance ===");
    console.log("aToken", aToken);
    
    console.log("creditAccount1", creditAccount1);
    
    
    const crditA1ATokenBalance = await aToken.balanceOf(creditAccount1);
    // should be 10 eth
    console.log("crditA1ATokenBalance", hre.ethers.formatEther(crditA1ATokenBalance));
    const crditA1UnderlyingTokenBalance = await underlyingToken.balanceOf(creditAccount1);
    // should be 40 eth
    console.log("crditA1UnderlyingTokenBalance", hre.ethers.formatEther(crditA1UnderlyingTokenBalance));
  });
});

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
