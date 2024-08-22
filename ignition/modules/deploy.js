// import { buildModule, useDeploy } from '@nomicfoundation/hardhat-ignition/modules';
const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");
const hre = require("hardhat");

module.exports = buildModule("DeploymentModule", (m) => {
  // Deploy LinearInterestRateModel
  const linearInterestRateModel = m.contract("LinearInterestRateModel", [
    5000, // U_1 (in basis points, e.g., 50%)
    8000, // U_2 (in basis points, e.g., 80%)
    200, // R_base (in basis points, e.g., 2%)
    400, // R_slope1 (in basis points, e.g., 4%)
    800, // R_slope2 (in basis points, e.g., 8%)
    1500, // R_slope3 (in basis points, e.g., 15%)
    true, // isBorrowingMoreU2Forbidden
  ]);

  // Deploy AddressProvider
  const addressProvider = m.contract("AddressProvider");

  // Deploy AccountFactory
  const accountFactory = m.contract("AccountFactory");

  // After deploying AccountFactory, set its address in AddressProvider
  m.call(addressProvider, "setAddress", [
    hre.ethers.encodeBytes32String("ACCOUNT_FACTORY"),
    accountFactory,
  ]);

  // Deploy UnderlyingToken
  const underlyingToken = m.contract("UnderlyingToken");

  // Deploy Pool
  const pool = m.contract("Pool", [
    addressProvider,
    underlyingToken,
    linearInterestRateModel,
    hre.ethers.parseEther("1000"),
    "pool_token",
    "pool_token_symbol",
  ]);

  // Deploy CreditManager
  const creditManager = m.contract("CreditManager", [addressProvider, pool]);

  // Deploy CreditFacade
  const creditFacade = m.contract("CreditFacade", [creditManager]);

  // Initialize contracts
  m.call(creditManager, "setCreditFacade", [creditFacade]);
  m.call(accountFactory, "addCreditManager", [creditManager]);
  m.call(pool, "setCreditManagerDebtLimit", [
    creditManager,
    hre.ethers.parseEther("1000"),
  ]);

  // Optionally, you can add logic to retrieve and check the debt limit
  m.call(pool, "creditManagerDebtLimit", [creditManager]);
  m.call(pool, "totalDebtLimit");
});
