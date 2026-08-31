import { z } from "zod";
export const profileSchema = z.object({
  name: z.string().trim().min(1).max(100),
  email: z
    .string()
    .trim()
    .email()
    .max(254)
    .transform((v) => v.toLowerCase()),
  password: z.string().min(12).max(128).optional(),
  role: z.enum(["admin", "mitarbeiter"]),
  color: z.enum([
    "green",
    "blue",
    "purple",
    "orange",
    "rose",
    "slate",
    "mint",
    "sage",
    "teal",
    "sky",
    "periwinkle",
    "lavender",
    "pink",
    "peach",
    "butter",
    "sand",
  ]),
  default_column_id: z.string().uuid().nullable(),
  default_workspace_id: z.string().uuid().optional(),
  active: z.boolean(),
});
export const createProfileSchema = profileSchema.extend({
  password: z.string().min(12).max(128),
});
export function canEditProfile(
  actorId: string,
  targetId: string,
  input: { role: string; active: boolean },
) {
  return actorId !== targetId || (input.active && input.role === "admin");
}
