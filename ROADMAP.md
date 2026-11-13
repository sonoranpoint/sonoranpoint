# Sonoran Point — to do

Ideas and planned work, newest requests at the bottom of each list. Move an item to CLAUDE.md once it's built.

## Up next
- Build one real station: a Raspberry Pi, a PN532 reader, a touchscreen and a USB barcode scanner. Test badge taps, the offline queue,
  Wi-Fi setup and a signed self-update on real hardware. Until now everything on the Pi has only been tested in simulation.
- Set up the PHX T3 pilot in the console: locations and contracts, leads, import employees and equipment, print labels.
- Walk through the new roles on the live site (migrations 41 and 42): make a test employee a Supervisor from their page, accept the invite,
  and check what they can and can't do.
- Billing per contract: decide how it works (Stripe, invoices by hand, or a count per contract in the console).

## Inventory module (requested 2026-11-13)
- Upload an inventory list (spreadsheet or form) for a company or contract.
- Scan items in and out against that list at a station or in the dashboard (barcode or NFC).
- Write the counts back out in the same shape as the list they uploaded (export to that form).
- See it on the dashboard: what's on hand, what's out, what's missing, counts over time.
- Open questions: consumables (counts that go down) vs. tracked items (each one has a tag)? Restock levels and alerts?
  One list per contract or per location? Which form do they need it output to (send a sample)?

## Work messaging (requested 2026-11-13)
- Chat inside Sonoran Point so employees' phone numbers stay private.
- Shift chats close at the end of the day but are kept so leaders can look back at them.
- Pick who's on shift and they get the messages.
- Separate chats for leadership.
- Tags to ping groups:
  - Leadership: `@mod`, `@sup`, `@lead`
  - Shifts: `@pm`, `@mid` (and the others)
  - Departments: `@jan`, `@sky`, `@cabin`, `@lav`
- Open questions: on phones (web app with notifications) or only at stations and on the dashboard? How do agents with no dashboard
  access sign in (badge number + PIN, a texted link)? Who can read closed chats, and for how long are they kept?
  Do departments map to contracts or need their own list?
