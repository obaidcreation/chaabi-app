# Chaabi.com app: live karne ke steps

Folder mein kya hai:
- `site/` : app (index.html + netlify.toml). Netlify par yahi folder upload hota hai.
- `supabase/schema.sql` : poora database, security rules aur photo storage.
- `supabase/functions/send-proof-email/index.ts` : Gmail se proof email bhejne wala function.
- `supabase/email-templates/` : verification aur password reset ki branded emails.

## 1. Business Gmail (5 min)
1. Naya Gmail banayein, misal ke taur par chaabi.official@gmail.com (apna personal Gmail use na karein).
2. myaccount.google.com > Security > 2-Step Verification ON karein.
3. myaccount.google.com/apppasswords > naam "Chaabi" > 16 letters wala App Password copy kar ke rakh lein.

## 2. Supabase (10 min)
1. supabase.com par free account aur New project banayein (region: Singapore ya Mumbai).
2. SQL Editor > New query > `schema.sql` poora paste > Run.
3. Authentication > Sign In / Providers > Email: "Confirm email" ON rehne dein.
4. Authentication > Emails > SMTP Settings > Enable custom SMTP:
   - Host `smtp.gmail.com`, Port `465`, Username = business Gmail, Password = App Password, Sender name `Chaabi.com`, Sender email = business Gmail.
5. Authentication > Emails > Templates: "Confirm signup" aur "Reset password" mein `email-templates` wali files ka HTML paste karein.
6. Edge Functions > Deploy a new function > Via editor > naam `send-proof-email` > `functions/send-proof-email/index.ts` paste > Deploy.
7. Isi tarah doosra function `ai-agent` > `functions/ai-agent/index.ts` paste > Deploy.
8. Edge Functions > Secrets: `GMAIL_USER` = business Gmail, `GMAIL_APP_PASSWORD` = App Password.
9. AI Expert ke liye (paid, har sawal par kharcha): console.anthropic.com se API key banayein, Secrets mein `ANTHROPIC_API_KEY` daalein, aur app mein `AI_ENABLED:true` kar dein.
10. Project Settings > API: "Project URL" aur "anon public" key copy karein.

## 3. App mein keys
`site/index.html` kholein, upar `CONFIG` mein `SUPABASE_URL` aur `SUPABASE_ANON_KEY` paste karein. (anon key public hoti hai, service_role key kabhi app mein na daalein.)

## 4. Netlify
1. Project "chaabi-app" pehle se bana hua hai: app.netlify.com/projects/chaabi-app > Deploys > `site` folder drag karein.
   Public karne ke liye: Project configuration > Access & security > Visitor access mein "Team login" band karein.
2. Jo link mile (misal: chaabi.netlify.app), usay Supabase > Authentication > URL Configuration mein "Site URL" aur "Redirect URLs" mein daalein.

## 5. Khud ko admin banayein
App par apne business Gmail se sign up aur verify karein, phir Supabase SQL Editor mein `schema.sql` ke aakhir wali `update ... is_admin = true` line apni email ke saath chalayein. Ab Account > Review queue se listings approve hongi.

## Maps ke baare mein
- Map OpenStreetMap ka hai (free, poori duniya ki sarkein, shehar aur jagahein). Satellite view Esri ka hai.
- Jagah ki search Nominatim se hoti hai: free hai lekin 1 search per second ki had hai. Bohat traffic aaye to paid geocoding lagani hogi.
- Asli Google Maps ke andar lagane ke liye Google Cloud API key aur card (billing) chahiye. Abhi har listing par "Open in Google Maps" aur "Directions" button hai.

Note: Supabase free project 7 din bilkul use na ho to pause ho jata hai; dashboard se Resume karein. Gmail roz taqreeban 500 emails tak bhejta hai.

## Install hone wali app
- Live link Chrome (Android/laptop) mein kholein: upar "Install app" button ya address bar ka install icon.
- iPhone: Safari > Share > Add to Home Screen.

## Play Store
1. play.google.com/console par Google Play Developer account (ek dafa $25 fee, ID verification).
2. pwabuilder.com par live link daalein > Package for stores > Android > package aur `assetlinks.json` download.
3. `assetlinks.json` website ke root par `/.well-known/assetlinks.json` hona chahiye. GitHub ke `/chaabi-app/` link par ye nahi chalta, is liye Play Store wala package Netlify link ya apne domain (chaabi.pk) se banayein.
4. Play Console > Create app > package upload. Naye personal account ke liye pehle 12 testers ka 14 din ka closed test zaroori hai, phir production.

## App ko registered banana
Ye kaam aap ke naam se hote hain (main nahi kar sakta): FBR NTN, FBR mein real estate agent (DNFBP) registration, Islamabad ke liye ICT RERA, IPO Pakistan mein "Chaabi" trademark, aur domain (chaabi.pk). Is ke baad app ke footer mein registration number likhein.

## Prices badalna
`ext.js` (aur live `index.html`) mein `PRICES` mein dealer plans aur services ki qeematein hain. Ye meri suggested qeematein hain.
