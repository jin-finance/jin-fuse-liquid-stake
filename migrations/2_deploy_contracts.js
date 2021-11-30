const JinFuseStakingPool = artifacts.require('JinFuseStakingPool');
const JinFuseProxy = artifacts.require('JinFuseProxy');
const SFuse = artifacts.require('SFuse');



module.exports = async function (deployer, network, accounts) {

   //minimal deployment
   await deployer.deploy(JinFuseStakingPool);
   await deployer.deploy(JinFuseProxy, JinFuseStakingPool.address, 180); //180s -- testing only
   await deployer.deploy(SFuse);

};