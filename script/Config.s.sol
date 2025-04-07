// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";

abstract contract Config is Script {
    uint256 deployerKey;
    address multisigAddress;
    address timelockAddress;
    address governorAddress;
    address guardianAddress;
    address farmManagerAddress;
    // AUDIT: This is a very dangerous assignment!
    address oracleManagerAddress;
    string env;

    uint256 constant RECEIPT_TOKEN_ORACLE_PRECISION = 1e18; // 1$ with 18 decimals of precision
    uint256 constant COLLATERAL_ORACLE_NORMALIZATION = 1e30; // 1$ + 12 decimals of normalization
    address constant USDC_MAINNET_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    constructor() {
        uint256 _env = vm.parseUint(vm.prompt("Enter environment [0 - development, 1 - production]:"));
        require(_env <= 1, "Invalid input");
        env = _env == 0 ? "development" : "production";
        deployerKey =
            vm.envOr("ETH_PRIVATE_KEY", 77814517325470205911140941194401928579557062014761831930645393041380819009408);
        multisigAddress = vm.envAddress("MULTISIG_ADDRESS");
        timelockAddress = vm.envAddress("TIMELOCK_ADDRESS");
        governorAddress = vm.envAddress("GOVERNOR_ADDRESS");
        guardianAddress = vm.envAddress("GUARDIAN_ADDRESS");
        farmManagerAddress = vm.envAddress("FARM_MANAGER_ADDRESS");
        // AUDIT: This is a very dangerous assignment!
        oracleManagerAddress = vm.envAddress("ORACLE_MANAGER_ADDRESS");
    }
}
