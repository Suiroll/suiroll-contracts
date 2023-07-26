import {
  Ed25519Keypair,
  JsonRpcProvider,
  RawSigner,
  localnetConnection,
  TransactionBlock,
} from "@mysten/sui.js"
import config from "./config.json" assert { type: "json" }
import publish_result from "./publish_result.json" assert { type: "json" }

const {privateKey, withdrawAmount} = config;

const secretKey = Uint8Array.from(Buffer.from(privateKey, "hex"));
const keypair = Ed25519Keypair.fromSecretKey(secretKey);
const provider = new JsonRpcProvider(localnetConnection);
const signer = new RawSigner(keypair, provider);

const withdrawFees = async () => {
  const txb = new TransactionBlock()

  txb.moveCall({
    target: `${publish_result.packageId}::suiroll::withdraw_funds`,
    typeArguments: ["0x2::sui::SUI"],
    arguments: [
      txb.object(publish_result.adminCapId),
      txb.object(publish_result.houseId),
      txb.pure(withdrawAmount),
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
  await withdrawFees();
}

main()
.then(() => console.log("Funds sent to treasury account"))
.catch((error) => console.log("Error: ", error))
