require('dotenv').config()
const JinFuseStakingPool = artifacts.require('JinFuseStakingPool');
const JinFuseProxy = artifacts.require('JinFuseProxy');
const SFuse = artifacts.require('SFuse');

const {
   INITIAL_VALIDATOR_ADDRESS,
   TIMELOCK,
   CONSENSUS,
   TREASURY,
   TIME_LOG,
   SYSTEM_LIMIT,
   TIME_INTERVAL
 } = process.env


module.exports = async function (deployer, network, accounts) {

   let implementation, proxy, token, impl;

   //minimal deployment
   implementation = await JinFuseStakingPool.new();
   proxy = await JinFuseProxy.new(implementation.address, TIMELOCK);
   token = await SFuse.new();


   //transfer token ownership to contract
   await token.transferOwnership(proxy.address);   
   
   //initialize
   impl = await JinFuseStakingPool.at(proxy.address);
   await impl.initialize(INITIAL_VALIDATOR_ADDRESS, CONSENSUS, token.address, TREASURY, TIME_LOG, SYSTEM_LIMIT, TIME_INTERVAL);


};