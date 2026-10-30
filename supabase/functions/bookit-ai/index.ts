import {createAIHandler} from './handler.js';
Deno.serve(createAIHandler({env:(name:string)=>Deno.env.get(name)}));
