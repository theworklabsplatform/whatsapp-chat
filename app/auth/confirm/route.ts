import { createClient, createServiceRoleClient } from "@/lib/supabase/server";
import { type EmailOtpType } from "@supabase/supabase-js";
import { redirect } from "next/navigation";
import { type NextRequest } from "next/server";

export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url);
  const token_hash = searchParams.get("token_hash");
  const type = searchParams.get("type") as EmailOtpType | null;
  const next = searchParams.get("next") ?? "/";
  const code = searchParams.get("code");

  if (token_hash && type) {
    const supabase = await createClient();

    const { data, error } = await supabase.auth.verifyOtp({
      type,
      token_hash,
    });
    if (!error) {
      // Insert into public.users if this is a signup confirmation
      if (type === "signup" && data.user) {
        const serviceClient = createServiceRoleClient();
        await serviceClient.from("users").upsert({
          id: data.user.id,
          name: data.user.user_metadata?.full_name || data.user.email || "User",
        }, { onConflict: "id" });
      }
      // redirect user to specified redirect URL or root of app
      return redirect(next);
    } else {
      // redirect the user to an error page with some instructions
      return redirect(`/auth/error?error=${error?.message}`);
    }
  }

  // Handle PKCE code exchange
  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      return redirect(next);
    } else {
      return redirect(`/auth/error?error=${error?.message}`);
    }
  }

  // redirect the user to an error page with some instructions
  return redirect(`/auth/error?error=No token hash, type, or code`);
}
