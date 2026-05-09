const { verifySession } = require('../services/customAuth');

async function customAuthMiddleware(req, res, next) {
  const authHeader = req.headers.authorization;
  
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing or invalid authorization header' });
  }

  const token = authHeader.split(' ')[1];

  try {
    const { user, session } = await verifySession(token);
    req.user = user;
    req.session = session;
    next();
  } catch (err) {
    return res.status(401).json({ error: err.message });
  }
}

module.exports = customAuthMiddleware;
