import app from "../server.js";
import { startEmailNotificationWorker } from "./email-notifications.js";

const port = Number(process.env.PORT || 3001);
const server = app.listen(port, "0.0.0.0", () =>
  console.log("SIMPL API listening on port " + port),
);
const emailWorker = startEmailNotificationWorker();

let stopping = false;
function stop() {
  if (stopping) return;
  stopping = true;
  emailWorker.stop();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10_000).unref();
}
process.once("SIGTERM", stop);
process.once("SIGINT", stop);
