import { viem } from "hardhat";
async function deployContract() {
    const publicClient = await viem.getPublicClient();
    const [deployer, otherAccount] = await viem.getWalletClients();
    const eCommerceContract = await viem.deployContract("Dashboard");
    
    return { publicClient, deployer, otherAccount, eCommerceContract };
}
deployContract().then((res)=>console.log(res.eCommerceContract.address));
// 0x6c0c2728a165ebe4a27884884d415db446c62a18