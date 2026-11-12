import {createClient} from 'npm:@supabase/supabase-js@2.57.4';
import {createHandler} from './handler.js';
Deno.serve(createHandler({createClient,env:(name:string)=>Deno.env.get(name)}));
