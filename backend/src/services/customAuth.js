require('../config/env');
const bcrypt = require('bcrypt');
const { v4: uuidv4 } = require('uuid');
const { supabase } = require('../config/supabase');

const SALT_ROUNDS = 10;

async function registerUser(email, password, fullName, role = 'operator') {
  // Check if user exists
  const { data: existing } = await supabase
    .from('app_users')
    .select('id')
    .eq('email', email)
    .single();

  if (existing) {
    throw new Error('User already exists');
  }

  // Hash password
  const hashedPassword = await bcrypt.hash(password, SALT_ROUNDS);

  // Create user
  const { data: user, error } = await supabase
    .from('app_users')
    .insert({
      email,
      password: hashedPassword,
      full_name: fullName,
      role
    })
    .select()
    .single();

  if (error) throw new Error('Failed to create user: ' + error.message);

  // Create session
  const session = await createSession(user.id);

  const { password: _, ...userWithoutPassword } = user;
  return { user: userWithoutPassword, session };
}

async function loginUser(email, password) {
  const { data: user, error } = await supabase
    .from('app_users')
    .select('*')
    .eq('email', email)
    .single();

  if (error || !user) {
    throw new Error('Invalid email or password');
  }

  if (!user.is_active) {
    throw new Error('Account is disabled');
  }

  const valid = await bcrypt.compare(password, user.password);
  if (!valid) {
    throw new Error('Invalid email or password');
  }

  // Update last login
  await supabase
    .from('app_users')
    .update({ last_login: new Date().toISOString() })
    .eq('id', user.id);

  // Create new session
  const session = await createSession(user.id);

  const { password: _, ...userWithoutPassword } = user;
  return { user: userWithoutPassword, session };
}

async function createSession(userId, expiresInHours = 24) {
  const token = uuidv4();
  const expiresAt = new Date(Date.now() + expiresInHours * 60 * 60 * 1000);

  const { data: session, error } = await supabase
    .from('sessions')
    .insert({
      user_id: userId,
      token,
      expires_at: expiresAt.toISOString()
    })
    .select()
    .single();

  if (error) throw new Error('Failed to create session');

  return {
    token: session.token,
    expires_at: session.expires_at,
    user_id: session.user_id
  };
}

async function verifySession(token) {
  const { data: session, error } = await supabase
    .from('sessions')
    .select('*, app_users(*)')
    .eq('token', token)
    .single();

  if (error || !session) {
    throw new Error('Invalid session');
  }

  if (new Date(session.expires_at) < new Date()) {
    await supabase.from('sessions').delete().eq('token', token);
    throw new Error('Session expired');
  }

  const { password, ...userWithoutPassword } = session.app_users;
  return {
    user: userWithoutPassword,
    session: {
      token: session.token,
      expires_at: session.expires_at
    }
  };
}

async function logoutUser(token) {
  const { error } = await supabase
    .from('sessions')
    .delete()
    .eq('token', token);

  if (error) throw new Error('Failed to logout');
  return { success: true };
}

async function getUserById(userId) {
  const { data: user, error } = await supabase
    .from('app_users')
    .select('id, email, full_name, role, is_active, created_at, last_login')
    .eq('id', userId)
    .single();

  if (error) throw new Error('User not found');
  return user;
}

module.exports = {
  registerUser,
  loginUser,
  verifySession,
  logoutUser,
  getUserById
};
