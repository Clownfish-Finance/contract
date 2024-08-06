// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.24;


struct CollateralDebtData {
    uint256 debt;                           
    uint256 cumulativeIndexNow;            
    uint256 cumulativeIndexLastUpdate;    
    uint256 accruedInterest;               
    uint256 accruedFees;                   
    uint256 totalValue;                    
}



interface ICreditManager  {
    
}
