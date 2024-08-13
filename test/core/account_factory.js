const { expect } = require("chai");
const hre = require("hardhat");
const {
  loadFixture,
  time,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const AP_ACCOUNT_FACTORY = "ACCOUNT_FACTORY";

const ICreditFacadeMulticallABI = [
  "function increaseDebt(uint256 amount) external",
  "function addCollateral(address token, uint256 amount) external",
];

function setupEventListeners({
  creditFacade,
  accountFactory,
  underlyingToken,
  pool,
  creditManager,
}) {
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

    // log address
    console.log("account1", account1.address);
    console.log("account2", account2.address);
    // log contract address
    console.log("creditFacade", creditFacade.target);
    console.log("creditManager", creditManager.target);
    console.log("accountFactory", accountFactory.target);
    console.log("pool", pool.target);
    console.log("underlyingToken", underlyingToken.target);

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
    };
  }

  // it("openCreditAccount not multicall", async function () {
  //   const { creditFacade, account1 } = await loadFixture(deploy);
  //   await creditFacade.openCreditAccount(account1, []);
  //   await delay(1000);
  // });

  // it("addCollateral multicall", async function () {
  //   const {
  //     creditFacade,
  //     accountFactory,
  //     underlyingToken,
  //     pool,
  //     creditManager,
  //     iCreditFacadeMulticall,
  //     account1,
  //   } = await loadFixture(deploy);
  //   let curCreditAccount;
  //   await creditFacade.openCreditAccount(account1, []);
  //   await delay(1000);

  //   const amount = hre.ethers.parseEther("100");
  //   await underlyingToken.mint(account1.address, amount);
  //   await underlyingToken.approve(creditManager.target, amount);

  //   const addCollateralEncode = iCreditFacadeMulticall.encodeFunctionData("addCollateral", [
  //     underlyingToken.target,
  //     amount / 2n,
  //   ]);

  //   console.log("addCollateralEncode", addCollateralEncode);

  //   const callData = [
  //     {
  //       target: creditFacade,
  //       callData: addCollateralEncode,
  //     },
  //   ];

  //   await creditFacade.multicall(curCreditAccount, callData);
  //   await delay(1000);

  //   expect(await underlyingToken.balanceOf(curCreditAccount)).to.equal(
  //     amount / 2n
  //   );
  // });

  it("deposit liquidity & borrow debt multicall", async function () {
    const {
      creditFacade,
      accountFactory,
      underlyingToken,
      pool,
      creditManager,
      iCreditFacadeMulticall,
      account1,
      account2,
    } = await loadFixture(deploy);

    let creditAccount1, creditAccount2;

    creditFacade.on(
      "OpenCreditAccount",
      (creditAccount, onBehalfOf, caller) => {
        if (onBehalfOf === account1.address) {
          creditAccount1 = creditAccount;
        } else {
          creditAccount2 = creditAccount;
        }
      }
    );

    await creditFacade.openCreditAccount(account1, []);
    await creditFacade.openCreditAccount(account2, []);

    await delay(1000);
    // crdit account
    console.log("creditAccount1", creditAccount1);
    console.log("creditAccount2", creditAccount2);

    //a1, a2 mint 100 ETH underlyingToken 
    const initMintAmount = hre.ethers.parseEther("100");
    await underlyingToken.mint(account1.address, initMintAmount);
    await underlyingToken.approve(creditManager.target, initMintAmount);
    await underlyingToken
      .connect(account2)
      .mint(account2.address, initMintAmount);
    await underlyingToken
      .connect(account2)
      .approve(pool.target, initMintAmount);

    //a2 deposit 50 ETH underlyingToken to pool, exchange to 50 poolToken
    await pool
      .connect(account2)
      .deposit(hre.ethers.parseEther("50"), account2.address);
    await delay(1000);
    const a2PoolBalance = await pool.balanceOf(account2);
    console.log("a2PoolBalance: ", hre.ethers.formatEther(a2PoolBalance));

    //a1 borrow 10 ETH underlyingToken
    const increaseDebtCallData = iCreditFacadeMulticall.encodeFunctionData(
      "increaseDebt",
      [hre.ethers.parseEther("10")]
    );

    const callData = [
      {
        target: creditFacade,
        callData: increaseDebtCallData,
      },
    ];

    await creditFacade.multicall(creditAccount1, callData);
    await delay(1000);
    const creditManagerBorrow = await pool.creditManagerBorrowed(
      creditManager.target
    );
    console.log(
      "creditManagerBorrow on pool",
      hre.ethers.formatEther(creditManagerBorrow)
    );

    await printBalance(creditAccount1, creditAccount2, underlyingToken);
  });
});

async function printBalance(creditAccount1, creditAccount2, underlyingToken) {
  console.log(
    "creditAccount1 underlyingToken:",
    hre.ethers.formatEther(await underlyingToken.balanceOf(creditAccount1))
  );
  console.log(
    "creditAccount2 underlyingToken:",
    hre.ethers.formatEther(await underlyingToken.balanceOf(creditAccount2))
  );
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
