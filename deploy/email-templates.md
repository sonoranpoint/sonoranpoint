# Supabase email templates

Supabase → **Authentication → Emails → Templates**. For each template below: paste the **Subject**, then switch the body to **Source** (HTML) and replace everything with the matching file from `deploy/email-templates/`.
The logo loads from `https://app.sonoranpoint.com/brand/logo.png`, so deploy the app site first.

## Magic Link

Subject: `Your Sonoran Point sign-in link`

Body: `email-templates/magic-link.html`

## Confirm signup

Subject: `You're invited to Sonoran Point`

Body: `email-templates/confirm-signup.html`

## Invite user

Subject: `You're invited to Sonoran Point`

Body: `email-templates/invite-user.html`

## Reset Password

Subject: `Set a new Sonoran Point password`

Body: `email-templates/reset-password.html`

## Change Email Address

Subject: `Confirm your new email for Sonoran Point`

Body: `email-templates/change-email-address.html`
