const JinFuseStakingPool = artifacts.require('JinFuseStakingPool');
const EternalStorageProxy = artifacts.require('EternalStorageProxy');

module.exports = function(deployer){
   deployer
     .deploy(JinFuseStakingPool)
     .then(() =>
        deployer.deploy(EternalStorageProxy, JinFuseStakingPool.address, 86400)
     );
};