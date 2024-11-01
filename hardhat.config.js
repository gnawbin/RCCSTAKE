/** @type import('hardhat/config').HardhatUserConfig */
require("@nomicfoundation/hardhat-toolbox");

module.exports = {
  solidity: "0.8.20",
  networks: {
    ganache: {
      url: "http://127.0.0.1:8545",
      accounts: ["0x56f3d77274b35d709cfbdcb4bc38fc90cbe2313573332da7ec6dda0836694068"]
    }
  },
  settings: {
    optimizer: {
      enabled: true,
    },
  },
  allowUnlimitedContractSize: true
};
