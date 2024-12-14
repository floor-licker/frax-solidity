// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.11;
import "../../Math/Math.sol";
contract TestDriftingReserves {
    uint end_dift;
    uint last_update_time;
    uint fxs_virtual_reserves;
    uint collat_virtual_reserves;
    uint drift_fxs_positive;
    uint drift_fxs_negative;
    uint drift_collat_positive;
    uint drift_collat_negative;
    uint fxs_price_cumulative;
    uint fxs_price_cumulative_prev;
    uint minting_fee;
    uint last_drift_refresh;
    uint drift_refresh_period;

    // Example reserve update flow
    function mint(uint fxs_amount) external {
        // Get current reserves
        (uint current_fxs_virtual_reserves,uint current_collat_virtual_reserves, uint average_fxs_virtual_reserves, uint average_collat_virtual_reserves) = getVirtualReserves();
        
        // Calc reserve updates
        uint total_frax_mint = getAmountOut(fxs_amount, current_fxs_virtual_reserves, current_collat_virtual_reserves);
        
        // Call _update with new reserves and average over last period
        _update(current_fxs_virtual_reserves + fxs_amount, current_collat_virtual_reserves - total_frax_mint, average_fxs_virtual_reserves, average_collat_virtual_reserves);
    }

    // Updates the reserve drifts
    function refreshDrift() external {
        require(block.timestamp >= end_dift, "Drift refresh on cooldown");
        
        // First apply the drift of the previous period
        (uint current_fxs_virtual_reserves,uint current_collat_virtual_reserves, uint average_fxs_virtual_reserves, uint average_collat_virtual_reserves) = getVirtualReserves();
        _update(current_fxs_virtual_reserves, current_collat_virtual_reserves, average_fxs_virtual_reserves, average_collat_virtual_reserves);
        
        
        // Calculate the reserves at the average internal price over the last period and the current K
        uint time_elapsed = block.timestamp - last_drift_refresh;
        uint average_period_price_fxs = (fxs_price_cumulative-fxs_price_cumulative_prev) / time_elapsed;
        uint internal_k = current_fxs_virtual_reserves * current_collat_virtual_reserves;
        uint collat_reserves_average_price = sqrt(internal_k * average_period_price_fxs);
        uint fxs_reserves_average_price = internal_k / collat_reserves_average_price;
        
        // Calculate the reserves at the average external price over the last period and the target K
        (uint ext_average_fxs_usd_price, uint ext_k) = getOracleInfo();
        uint targetK = Math.min(ext_k,internal_k + internal_k / 100); // Increase K with max 1% per period
        uint ext_collat_reserves_average_price = sqrt(targetK * ext_average_fxs_usd_price);
        uint ext_fxs_reserves_average_price = targetK / ext_collat_reserves_average_price;
        
        // Calculate the drifts per second
        if (collat_reserves_average_price<ext_collat_reserves_average_price) {
            drift_collat_positive=(ext_collat_reserves_average_price-collat_reserves_average_price) / drift_refresh_period;
            drift_collat_negative=0;
        } else {
            drift_collat_positive=0;
            drift_collat_negative=(collat_reserves_average_price-ext_collat_reserves_average_price) / drift_refresh_period;
        }
        if (fxs_reserves_average_price<ext_fxs_reserves_average_price) {
            drift_fxs_positive=(ext_fxs_reserves_average_price-fxs_reserves_average_price) / drift_refresh_period;
            drift_fxs_negative=0;
        } else {
            drift_fxs_positive=0;
            drift_fxs_negative=(fxs_reserves_average_price-ext_fxs_reserves_average_price) / drift_refresh_period;
        }
        
        fxs_price_cumulative_prev = fxs_price_cumulative;
        last_drift_refresh = block.timestamp;
        end_dift = block.timestamp + drift_refresh_period;
    }
    
    // Gets the external average fxs price over the previous period and the external K
    function getOracleInfo() internal returns (uint ext_average_fxs_usd_price, uint ext_k) {
        // TODO 
    }

    // Update the reserves and the cumulative price
    function _update(uint current_fxs_virtual_reserves, uint current_collat_virtual_reserves, uint average_fxs_virtual_reserves, uint average_collat_virtual_reserves) private {
        uint time_elapsed = block.timestamp - last_update_time; 
        if (time_elapsed > 0) {
            fxs_price_cumulative += average_fxs_virtual_reserves * 1e18 / average_collat_virtual_reserves * time_elapsed;
        }
        fxs_virtual_reserves = current_fxs_virtual_reserves;
        collat_virtual_reserves = current_collat_virtual_reserves;
        last_update_time = block.timestamp;
    }
    
    // Returns the current reserves and the average reserves over the last period
    function getVirtualReserves() public view returns (uint current_fxs_virtual_reserves,uint current_collat_virtual_reserves, uint average_fxs_virtual_reserves, uint average_collat_virtual_reserves) {
        current_fxs_virtual_reserves = fxs_virtual_reserves;
        current_collat_virtual_reserves = collat_virtual_reserves;
        uint256 drift_time=0;
        if (end_dift>last_update_time) {
            drift_time = Math.min(block.timestamp,end_dift)-last_update_time;
            if (drift_time>0) {
                if (drift_fxs_positive>0) current_fxs_virtual_reserves = current_fxs_virtual_reserves + drift_fxs_positive * drift_time;
                else current_fxs_virtual_reserves = current_fxs_virtual_reserves - drift_fxs_negative * drift_time;
                
                if (drift_collat_positive>0) current_collat_virtual_reserves = current_collat_virtual_reserves + drift_collat_positive * drift_time;
                else current_collat_virtual_reserves = current_collat_virtual_reserves - drift_collat_negative * drift_time;
            }
        }
        average_fxs_virtual_reserves = fxs_virtual_reserves + current_fxs_virtual_reserves / 2;
        average_collat_virtual_reserves = collat_virtual_reserves + current_collat_virtual_reserves / 2;
        
        // Adjust for when time was split between drift and no drift.
        uint time_elapsed = block.timestamp-last_update_time;
        if (time_elapsed>drift_time && drift_time>0) {
            average_fxs_virtual_reserves=average_fxs_virtual_reserves * drift_time + current_fxs_virtual_reserves * time_elapsed - drift_time / time_elapsed;
            average_collat_virtual_reserves=average_collat_virtual_reserves * drift_time + current_collat_virtual_reserves * time_elapsed - drift_time / time_elapsed;
        }
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) public view returns (uint amountOut) {
        require(amountIn > 0, 'FRAX_vAMM: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'FRAX_vAMM: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn * uint(1e6 - minting_fee);
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = (reserveIn * 1e6) + amountInWithFee;
        amountOut = numerator / denominator;
    }
    
    // SQRT from here: https://ethereum.stackexchange.com/questions/2910/can-i-square-root-in-solidity
    function sqrt(uint x) internal pure returns (uint y) {
        uint z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}