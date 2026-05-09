// Loads .env from the repo root regardless of where node is invoked from
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });
