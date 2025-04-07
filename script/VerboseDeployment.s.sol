// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {VmSafe} from "forge-std/Vm.sol";
import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

abstract contract VerboseDeployment is Script {
    string json = "";

    function outputAddressesToJson(string memory env) public {
        // only write to file if we're running in a script that broadcasts
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            string memory fileName = string.concat(Strings.toString(block.timestamp), "-infinifi-addresses.json");
            string memory output = string.concat("./deployments/", env, "/", fileName);
            console.log("Writing to file ./%s", output);
            vm.writeJson(json, output);
        }
    }
}
