import {
  Ed25519Keypair,
  JsonRpcProvider,
  RawSigner,
  localnetConnection,
  TransactionBlock,
  SUI_CLOCK_OBJECT_ID,
} from "@mysten/sui.js"
import config from "./config.json" assert { type: "json" }
import publish_result from "./publish_result.json" assert { type: "json" };

const secretKey = Uint8Array.from(Buffer.from("", "hex"));
const keypair = Ed25519Keypair.fromSecretKey(secretKey);
const provider = new JsonRpcProvider(localnetConnection);
const signer = new RawSigner(keypair, provider);

const withdrawFees = async () => {
  const txb = new TransactionBlock()

  txb.moveCall({
    target: `${publish_result.packageId}::suiroll::refund`,
    typeArguments: ["0x2::sui::SUI"],
    arguments: [
      txb.object("0x9d3318cef53e598f5faa9b8429d7fd2902a34325148592c831c85d71a21cb632"), //game object id with hex (0x prefixed string)
      txb.object(publish_result.houseId),
      txb.object(SUI_CLOCK_OBJECT_ID),
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
.then(() => console.log("Game refund"))
.catch((error) => console.log("Error: ", error))
