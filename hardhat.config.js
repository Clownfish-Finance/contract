require("@nomicfoundation/hardhat-toolbox");
const dotenv = require("dotenv");
dotenv.config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.24",
  defaultNetwork: "bsc_testnet",
  networks: {
    bsc_testnet: {
      url: process.env.BSC_TESTNET_URL,
      chainId: 97,
      accounts: [process.env.TEST_ACCOUNT_1],
    }
  },
  etherscan: {
    apiKey: process.env.BSC_TESTNET_SCAN_API_KEY,
  },
};
