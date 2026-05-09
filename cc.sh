cd /workspaces/settl/backend

# Read the actual keypair.json file properly
node -e "
const fs = require('fs');
const { Keypair } = require('@solana/web3.js');
const keypairData = JSON.parse(fs.readFileSync('keypair.json', 'utf-8'));
const keypair = Keypair.fromSecretKey(Uint8Array.from(keypairData));
console.log('Your ACTUAL keypair public key:', keypair.publicKey.toBase58());
"