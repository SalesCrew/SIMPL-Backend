import "dotenv/config";
import { createClient } from "@supabase/supabase-js";
import { cleanupAttachments } from "../src/attachments.js";
const admin = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SECRET_KEY!,
  { auth: { persistSession: false } },
);
const count = await cleanupAttachments(admin);
console.log(
  `Removed ${count} expired upload reservations and their stored objects.`,
);
