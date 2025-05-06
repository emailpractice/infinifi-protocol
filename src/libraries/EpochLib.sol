// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library EpochLib {
    uint256 internal constant EPOCH = 1 weeks;
    uint256 internal constant EPOCH_OFFSET = 3 days;

    /// @notice epoch start (start of the epoch) for a given timestamp
    function epoch(uint256 _timestamp) public pure returns (uint256) {
        return (_timestamp - EPOCH_OFFSET) / EPOCH;
    } //Timestamp是從1970 1/1 開始到現在的秒數 會是很大的數字
    /*
    比如(1622246400  - 86400(3天秒數) ) 去除掉一周，看現在是第幾周 就知道是第幾epoch，它會向下取整 */
    // 一周 604,800 秒， 600000秒就是第0週期， 6048001則是第一周期
    /// @notice epoch end (end of the epoch) for a given timestamp
    function nextEpoch(uint256 _timestamp) public pure returns (uint256) {
        return epoch(_timestamp) + 1;
    }

    /// @notice Convert epoch to timestamp taking into account the epoch offset
    function epochToTimestamp(uint256 _epoch) public pure returns (uint256) {
        return _epoch * EPOCH + EPOCH_OFFSET;
    } //這應該會得到的是一個周期的開始時間，因為_epoch有向下取整
}

/* 函數epoch的相反過來   
function epoch(uint256 _timestamp) public pure returns (uint256) {
        return (_timestamp - EPOCH_OFFSET) / EPOCH;
    } //Timestamp是從1970 1/1 開始到現在的秒數 會是很大的數字
    /*
    比如(1622246400  - 86400(3天秒數) ) 去除掉一周，看現在是第幾周 就知道是第幾epoch */
// 一周 604,800 秒， 600000秒就是第0週期， 6048001則是第一周期
