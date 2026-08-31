import "dotenv/config";
import { createClient } from "@supabase/supabase-js";
import { createProfileSchema } from "../src/validation.js";
// One-time, server-side operation. Supply credentials through environment variables.
const input = createProfileSchema.parse({
  name: process.env.ADMIN_NAME,
  email: process.env.ADMIN_EMAIL,
  password: process.env.ADMIN_PASSWORD,
  role: "admin",
  color: "green",
  active: true,
  default_column_id: null,
});
if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SECRET_KEY)
  throw new Error("Supabase server configuration missing.");
const admin = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SECRET_KEY,
  { auth: { persistSession: false, autoRefreshToken: false } },
);
const { data, error } = await admin.auth.admin.createUser({
  email: input.email,
  password: input.password,
  email_confirm: true,
});
if (error || !data.user)
  throw new Error(
    "Admin account creation failed. Verify that the account does not already exist.",
  );
const { password: _password, ...profile } = input;
const result = await admin
  .from("profiles")
  .insert({ ...profile, id: data.user.id });
if (result.error) {
  await admin.auth.admin.deleteUser(data.user.id);
  throw new Error("Profile creation failed; newly created Auth user removed.");
}
console.log(
  "Administrator created. Sign in to the frontend to manage the team.",
);
