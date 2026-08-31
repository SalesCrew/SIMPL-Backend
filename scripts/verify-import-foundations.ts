import "dotenv/config";
import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import request from "supertest";
import app from "../server.js";

const url = process.env.SUPABASE_URL!;
assert.equal(url,"https://xqvexzoswhraqicbmckj.supabase.co");
const options = { auth:{persistSession:false,autoRefreshToken:false} };
const admin = createClient(url,process.env.SUPABASE_SECRET_KEY!,options);
const api = process.env.TEST_API_URL || app;
const actors: string[] = [];
const cardIds: string[] = [];
const checked = <R extends {data:unknown;error:unknown}>(result:R):NonNullable<R["data"]> => {
  if(result.error)throw result.error;
  assert.notEqual(result.data,null);
  return result.data as NonNullable<R["data"]>;
};
try {
  const workspace = checked(await admin.from("workspaces").select("id").eq("name","Development").single());
  const columns = checked(await admin.from("columns").select("id,kind").eq("workspace_id",workspace.id));
  const project = columns.find(column => column.kind === "project")!.id;
  for(const role of ["admin","mitarbeiter"]){
    const email = `qa-import-foundation-${randomUUID()}@example.invalid`;
    const temporary = randomBytes(24).toString("base64url")+"Aa8!";
    const password = randomBytes(24).toString("base64url")+"Aa9!";
    const actor = checked(await admin.auth.admin.createUser({email,password:temporary,email_confirm:true})).user!.id;
    actors.push(actor);
    assert.ifError((await admin.from("profiles").insert({id:actor,email,name:"Disposable import verification",role,color:"sage",active:true,default_workspace_id:workspace.id,default_column_id:project})).error);
    const client: SupabaseClient = createClient(url,process.env.SUPABASE_PUBLISHABLE_KEY!,options);
    const initial = checked(await client.auth.signInWithPassword({email,password:temporary}));
    const change = await request(api).post("/api/account/initial-password").set("Authorization",`Bearer ${initial.session!.access_token}`).send({password,repeatPassword:password});
    assert.equal(change.status,200,change.text);
    checked(await client.auth.signInWithPassword({email,password}));
    const list = [{id:randomUUID(),name:"Original checklist",items:[{id:randomUUID(),name:"Preserved item",completed:false}]}];
    const ids=[randomUUID(),randomUUID(),randomUUID()];cardIds.push(...ids);
    assert.ifError((await client.from("cards").insert(ids.map((id,index)=>({id,title:`Disposable preservation fixture ${index}`,column_id:project,project_id:project,checklists:list})))).error);
    const session=randomUUID();
    const rpc=async(operation:string,action:unknown=null)=>client.rpc("card_edit_session",{p_session:session,p_operation:operation,p_card:ids[0],p_action:action});
    checked(await rpc("begin"));
    const changed=structuredClone(list);changed[0].items[0].completed=true;
    checked(await rpc("mutate",{type:"card.update",id:ids[0],patch:{checklists:changed}}));
    assert.deepEqual(checked(await client.from("cards").select("checklists").eq("id",ids[0]).single()).checklists,changed);
    const receipt=checked(await rpc("close"));
    assert.ok(receipt.events.some((event:{field:string})=>event.field==="checklists"));
    checked(await rpc("undo"));
    assert.deepEqual(checked(await client.from("cards").select("checklists").eq("id",ids[0]).single()).checklists,list);
    const invalid=await client.from("cards").update({checklists:[{...list[0],items:[{...list[0].items[0],completed:"yes"}]}]}).eq("id",ids[0]);
    assert.ok(invalid.error,"Malformed checklist accepted");
    assert.ifError((await admin.from("cards").update({archived_at:new Date().toISOString()}).eq("id",ids[1])).error);
    const archived=checked(await admin.from("cards").select("*").eq("id",ids[1]).single());
    assert.ifError((await client.rpc("move_card",{p_card:ids[2],p_column:project,p_before:ids[0]})).error);
    assert.deepEqual(checked(await admin.from("cards").select("*").eq("id",ids[1]).single()),archived,"Active move changed archive history");
    const deniedArchive=await client.rpc("card_edit_session",{p_session:randomUUID(),p_operation:"begin",p_card:ids[1]});
    assert.equal(deniedArchive.error?.code,"42501");
    const directArchive=await client.from("cards").update({title:"Forbidden archive overwrite"}).eq("id",ids[1]).select("id");
    assert.ok(directArchive.error || directArchive.data?.length===0);
    const knownSession=randomUUID();
    checked(await client.rpc("card_edit_session",{p_session:knownSession,p_operation:"begin",p_card:ids[0]}));
    const beforeReset=checked(await admin.from("cards").select("*").in("id",ids).order("id"));
    assert.ifError((await admin.rpc("require_password_change",{p_user:actor})).error);
    for(const operation of ["begin","touch","mutate","close","undo"]){
      const denied=await client.rpc("card_edit_session",{p_session:operation==="begin"?randomUUID():knownSession,p_operation:operation,p_card:ids[0],p_action:{type:"card.update",id:ids[0],patch:{title:"Gate bypass"}}});
      assert.equal(denied.error?.code,"42501",`Pending actor reached edit operation ${operation}`);
    }
    assert.equal(checked(await client.rpc("card_edit_cleanup",{p_card:ids[0],p_purge:false})),false);
    assert.ok((await client.rpc("card_edit_cleanup",{p_card:ids[0],p_purge:true})).error);
    assert.ok((await client.rpc("move_card",{p_card:ids[0],p_column:project})).error);
    assert.ok((await client.rpc("set_card_completed",{p_card:ids[0],p_completed:true})).error);
    const context=checked(await client.rpc("workspace_access_context"));
    assert.equal(context.profile,null);assert.deepEqual(context.workspaces,[]);
    assert.deepEqual(checked(await admin.from("cards").select("*").in("id",ids).order("id")),beforeReset,"Pending actor changed known-card state");
    await client.auth.signOut();
    console.log(`PASS ${role}: real checklist save/undo, invalid JSON denial, immutable archive during active moves, known-card RPC gate across begin/touch/mutate/close/undo/cleanup`);
  }
} finally {
  if(cardIds.length)assert.ifError((await admin.from("cards").delete().in("id",cardIds)).error);
  for(const id of actors)assert.ifError((await admin.auth.admin.deleteUser(id)).error);
}
console.log("PASS: all disposable cards/accounts removed; requested user accounts unchanged.");
