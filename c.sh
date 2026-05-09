cd /workspaces/settl/backend

# Get balance using curl to Solana RPC
node -e "
const { Connection, PublicKey } = require('@solana/web3.js');
const fs = require('fs');

async function checkBalance() {
  const keypairData = JSON.parse(fs.readFileSync('keypair.json', 'utf-8'));
  const { Keypair } = require('@solana/web3.js');
  const keypair = Keypair.fromSecretKey(Uint8Array.from(keypairData));
  
  const connection = new Connection('https://api.devnet.solana.com');
  const balance = await connection.getBalance(keypair.publicKey);
  
  console.log('Public Key:', keypair.publicKey.toBase58());
  console.log('Balance:', balance / 1e9, 'SOL');
}

checkBalance().catch(console.error);
"