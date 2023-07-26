import {
  Ed25519Keypair,
  JsonRpcProvider,
  RawSigner,
  localnetConnection,
  TransactionBlock,
} from "@mysten/sui.js"
import {writeFile} from "fs/promises"
import {execSync} from "child_process"
import config from "./config.json" assert { type: "json" }

const {
  privateKey, treasury, vrfPubkey, feeBp, minStake, maxStake,
} = config;

const secretKey = Uint8Array.from(Buffer.from(privateKey, "hex"));
const keypair = Ed25519Keypair.fromSecretKey(secretKey);
const provider = new JsonRpcProvider(localnetConnection);
const signer = new RawSigner(keypair, provider);

const publish = async () => {
  const cliPath = "sui";
  const packagePath = "sources";
  const {modules, dependencies} = JSON.parse(
    execSync(
      `${cliPath} move build --dump-bytecode-as-base64 --path ${packagePath}`,
      {encoding: "utf-8"},
    ),
  );

  const txb = new TransactionBlock();
  const [upgradeCap] = txb.publish({modules, dependencies});
  txb.transferObjects([upgradeCap], txb.pure(await signer.getAddress()));
  
  const result = await signer.signAndExecuteTransactionBlock({
    transactionBlock: txb,
    options: {showObjectChanges: true},
  });

  return result
}

const initConfig = async(packageId, adminCapId) => {
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${packageId}::suiroll::init_config`,
    typeArguments: [],
    arguments: [
      txb.object(adminCapId),
      txb.pure(vrfPubkey),
    ],
  });

  txb.setGasBudget(1_000_000_000)

  const result = await signer.signAndExecuteTransactionBlock({
    transactionBlock: txb,
    options: {showObjectChanges: true},
  })

  return result
}

const initHouse = async (packageId, adminCapId) => {
  const txb = new TransactionBlock();

  const [houseTopupCoin] = txb.splitCoins(txb.gas, [txb.pure(100_000_000_000)]);
  txb.moveCall({
    target: `${packageId}::suiroll::init_house`,
    typeArguments: ["0x2::sui::SUI"],
    arguments: [
      txb.object(adminCapId),
      txb.pure(treasury),
      houseTopupCoin,
      txb.pure(feeBp),
      txb.pure(minStake),
      txb.pure(maxStake),
    ],
  });

  txb.setGasBudget(1_000_000_000)

  const result = await signer.signAndExecuteTransactionBlock({
    transactionBlock: txb,
    options: {showObjectChanges: true},
  })

  return result
}

const main = async () => {
  console.log("Deployer: ", await signer.getAddress());

  const result = await publish();
  
  const {packageId} = result.objectChanges.find(o => o.type === "published");
  console.log("Published package: ", packageId)

  const adminCapId = result.objectChanges.find(o => o.objectType === `${packageId}::suiroll::AdminCap`).objectId;
  const initConfigResult = await initConfig(packageId, adminCapId);
  const configId = initConfigResult.objectChanges.find(o => o.objectType === `${packageId}::suiroll::Config`).objectId;
  
  const initHouseResult = await initHouse(packageId, adminCapId);
  const houseId = initHouseResult.objectChanges.find(o => o.objectType === `${packageId}::suiroll::House<0x2::sui::SUI>`).objectId;

  const data = {
    adminCapId,
    packageId,
    configId,
    houseId,
  };

  await writeFile(
    "scripts/publish_result.json",
    JSON.stringify(data, null, 2)
  )
}

main()
.then(() => console.log("Package published"))
.catch((error) => console.log("Error: ", error))
