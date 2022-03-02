//const StratX = artifacts.require("StratX");
//const BStratX = artifacts.require("BStratX");
/*
address _marsAutoFarmAddress,
address _marsTokenAddress,
address _dev25,
address _dev75
*/

module.exports = async (deployer, network) => {
  const mars="0x60322971a672B81BccE5947706D22c19dAeCf6Fb";
  const dev75="0x5733dc1a89627a499Fc2E82b205A4E04Adbc2F51";
  const dev25="0x2737D47BbE628B3Cb9740E70f5d6d46766671e91";
  const marsAvtofarm="0x5aEF70fb368b930f3129a5EcD795a6Bb2678C338";
  try{
    //deployer.deploy(StratX,marsAvtofarm,mars,dev25,dev75);
    //deployer.deploy(BStratX,marsAvtofarm,mars,dev25,dev75);
  }catch(err){
    console.log("ERROR:",err);
  }

};