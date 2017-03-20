/**
 *	[INS] RoundEndBlock Script - Prevent round end.
 *	
 *	This program is free software: you can redistribute it and/or modify
 *	it under the terms of the GNU General Public License as published by
 *	the Free Software Foundation, either version 3 of the License, or
 *	(at your option) any later version.
 *
 *	This program is distributed in the hope that it will be useful,
 *	but WITHOUT ANY WARRANTY; without even the implied warranty of
 *	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *	GNU General Public License for more details.
 *
 *	You should have received a copy of the GNU General Public License
 *	along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0"
#define PLUGIN_DESCRIPTION "Prevent round end."

#define REQUIRE_EXTENSIONS
#include <insurgencydy>

// This will be used for checking which team the player is on before repsawning them
#define SPECTATOR_TEAM	0
#define TEAM_SPEC 	1
#define TEAM_1		2
#define TEAM_2		3

new const String:g_sSecBot[] = "[INS] RoundEnd Protector";
new g_iSecBotID = -1;
new g_iScore = -100;
new g_iCollOff;

enum FX
{
	FxNone = 0,
	FxPulseFast,
	FxPulseSlowWide,
	FxPulseFastWide,
	FxFadeSlow,
	FxFadeFast,
	FxSolidSlow,
	FxSolidFast,
	FxStrobeSlow,
	FxStrobeFast,
	FxStrobeFaster,
	FxFlickerSlow,
	FxFlickerFast,
	FxNoDissipation,
	FxDistort,               // Distort/scale/translate flicker
	FxHologram,              // kRenderFxDistort + distance fade
	FxExplode,               // Scale up really big!
	FxGlowShell,             // Glowing Shell
	FxClampMinScale,         // Keep this sprite from getting very small (SPRITES only!)
	FxEnvRain,               // for environmental rendermode, make rain
	FxEnvSnow,               //  "        "            "    , make snow
	FxSpotlight,     
	FxRagdoll,
	FxPulseFastWider,
};

enum Render
{
	Normal = 0, 		// src
	TransColor, 		// c*a+dest*(1-a)
	TransTexture,		// src*a+dest*(1-a)
	Glow,				// src*a+dest -- No Z buffer checks -- Fixed size in screen space
	TransAlpha,			// src*srca+dest*(1-srca)
	TransAdd,			// src*a+dest
	Environmental,		// not drawn, used for environmental effects
	TransAddFrameBlend,	// use a fractional frame value to blend between animation frames
	TransAlphaAdd,		// src + dest*(1-a)
	WorldGlow,			// Same as kRenderGlow but not fixed size in screen space
	None,				// Don't render.
};

new FX:g_Effect = FX:FxGlowShell;
new Render:g_Render = Render:Glow;

public Plugin:info = {
	name = "RoundEnd Block",
	author = "naong",
	description = PLUGIN_DESCRIPTION,
	version = PLUGIN_VERSION
};

new Handle:sm_roundendblock_enabled = INVALID_HANDLE;
new Handle:sm_roundendblock_times = INVALID_HANDLE;
new Handle:sm_roundendblock_revive_delay = INVALID_HANDLE;
new Handle:sm_roundendblock_reset_each_round = INVALID_HANDLE;
new Handle:sm_roundendblock_debug = INVALID_HANDLE;
new g_iRoundEndBlockEnabled;
new g_iRoundEndBlockCapCount = 0;
new g_iRoundEndBlockMaxCapPoints = 3;
new g_iRoundEndBlockTimes;
new g_iRoundEndBlockReviveDelay;
new g_iRoundEndBlockResetRound;
new g_iRoundEndBlockDebug;
new playerPickSquad[MAXPLAYERS + 1];

new Handle:g_hGameConfig;
new Handle:g_hPlayerRespawn;
new Float:g_fSpawnPoint[3];

new g_iIsRoundStarted = 0; 	//0 is over, 1 is active
new g_iIsRoundStartedPost = 0; //0 is over, 1 is active
new g_iIsGameEnded = 0;		//0 is not ended, 1 is ended
new g_iRoundStatus = 0;
new g_iRoundBlockCount;
new g_iAnnounceActive;
new g_iReviveCount;
new g_max_AnnounceTime = 480;
new g_announceTick;
new g_isReviving = 0;

// Cvars for caupture point speed
new Handle:g_hCvarCPSpeedUp;
new Handle:g_hCvarCPSpeedUpMax;
new Handle:g_hCvarCPSpeedUpRate;
new g_iCPSpeedUp;
new g_iCPSpeedUpMax;
new g_iCPSpeedUpRate;
new g_bIsCounterAttackTimerActive = false;

public void OnPluginStart() {
	// cvars
	sm_roundendblock_enabled = CreateConVar("sm_roundendblock_enabled", "1", "Coop bot Enabled", FCVAR_NOTIFY);
	sm_roundendblock_times = CreateConVar("sm_roundendblock_times", "1", "How many times block rounds.");
	sm_roundendblock_revive_delay = CreateConVar("sm_roundendblock_revive_delay", "10", "When blocks RoundEnd, wait for reviving players.");
	sm_roundendblock_reset_each_round = CreateConVar("sm_roundendblock_reset_each_round", "1", "Reset block counter each round. (1 is reset / 0 is don't reset)");
	sm_roundendblock_debug = CreateConVar("sm_roundendblock_debug", "0", "1: Turn on debug mode, 0: Turn off");
	
	// register admin commands
	RegAdminCmd("sm_addblocker", Command_AddBlocker, ADMFLAG_SLAY, "sm_addblocker");
	RegAdminCmd("sm_kickblocker", Command_KickBlocker, ADMFLAG_SLAY, "sm_kickblocker");
	RegAdminCmd("sm_botcount", Command_BotCount, ADMFLAG_SLAY, "sm_botcount");
	
	g_iCollOff = FindSendPropOffs("CBaseEntity", "m_CollisionGroup");
	//g_iCollOff = FindSendPropInfo("CBaseEntity", "m_CollisionGroup");
	
	// hook events
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd_Pre, EventHookMode_Pre);	
	HookEvent("round_end", Event_RoundEnd_Post, EventHookMode_PostNoCopy);	
	HookEvent("game_start", Event_GameStart, EventHookMode_PostNoCopy);
	HookEvent("game_end", Event_GameEnd, EventHookMode_PostNoCopy);
	HookEvent("object_destroyed", Event_ObjectDestroyed_Post, EventHookMode_PostNoCopy);
	HookEvent("controlpoint_captured", Event_ControlPointCaptured_Pre, EventHookMode_Pre);
	HookEvent("controlpoint_captured", Event_ControlPointCaptured_Post, EventHookMode_PostNoCopy);
	HookEvent("player_death", Event_PlayerDeathPre, EventHookMode_Pre);
	HookEvent("player_pick_squad", Event_PlayerPickSquad_Post, EventHookMode_Post);
	HookEvent("player_connect", Event_PlayerConnect);
	HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
	
	// hook variables
	HookConVarChange(sm_roundendblock_enabled,CvarChange);
	HookConVarChange(sm_roundendblock_times,CvarChange);
	HookConVarChange(sm_roundendblock_reset_each_round,CvarChange);
	HookConVarChange(sm_roundendblock_debug,CvarChange);
	HookConVarChange(sm_roundendblock_revive_delay,CvarChange);
	
	// init respawn command
	g_hGameConfig = LoadGameConfigFile("insurgency.games");
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(g_hGameConfig, SDKConf_Signature, "ForceRespawn");
	g_hPlayerRespawn = EndPrepSDKCall();
	
	// create config file
	AutoExecConfig(true, "plugin.roundendblock");
	
	// init var
	g_iRoundEndBlockEnabled = GetConVarInt(sm_roundendblock_enabled);
	g_iRoundEndBlockTimes = GetConVarInt(sm_roundendblock_times);
	g_iRoundEndBlockReviveDelay = GetConVarInt(sm_roundendblock_revive_delay);
	g_iRoundEndBlockResetRound = GetConVarInt(sm_roundendblock_reset_each_round);
	g_iRoundEndBlockDebug = GetConVarInt(sm_roundendblock_debug);
	
	// init Cvars
	g_hCvarCPSpeedUp = FindConVar("mp_checkpoint_counterattack_capture_speedup");
	g_hCvarCPSpeedUpMax = FindConVar("mp_cp_speedup_max");
	g_hCvarCPSpeedUpRate = FindConVar("mp_cp_speedup_rate");
	
	// Get capture point speed cvar values
	g_iCPSpeedUp = GetConVarInt(g_hCvarCPSpeedUp);
	g_iCPSpeedUpMax = GetConVarInt(g_hCvarCPSpeedUpMax);
	g_iCPSpeedUpRate = GetConVarInt(g_hCvarCPSpeedUpRate);
}

public OnMapStart()
{	
	g_iSecBotID = 0;
	
	// Get capture point speed cvar values
	g_iCPSpeedUp = GetConVarInt(g_hCvarCPSpeedUp);
	g_iCPSpeedUpMax = GetConVarInt(g_hCvarCPSpeedUpMax);
	g_iCPSpeedUpRate = GetConVarInt(g_hCvarCPSpeedUpRate);

	g_announceTick = g_max_AnnounceTime;
	CreateTimer(1.0, Timer_AnnounceSaves, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	

}
public Action:Timer_AnnounceSaves(Handle:timer, any:data)
{

	g_announceTick--;
	if (g_announceTick <= 0)
	{
		decl String:textToPrint[64];
		decl String:textToHint[64];
		Format(textToPrint, sizeof(textToPrint), "\x03[Server] Remaining RoundEnd Saves: %d", g_iRoundBlockCount);
		Format(textToHint, sizeof(textToHint), "\x03[Server] Remaining RoundEnd Saves: %d", g_iRoundBlockCount);
		PrintToChatAll(textToPrint);
		PrintHintTextToAll(textToHint);
		g_announceTick = g_max_AnnounceTime;
	}

}
public Action:Command_AddBlocker(client, args) {
	//AddBlocker();
	PrintToChat(client, "[RndEndBlock] Added roundend blocker"); // show chat debug 
	
	return Plugin_Handled;
}
public Action:Command_KickBlocker(client, args) {
	KickBlocker();
	return Plugin_Handled;
}


// When player connected server, intialize variable
public OnClientPutInServer(client)
{
		playerPickSquad[client] = 0;
}

public Action:Event_PlayerConnect(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	
		playerPickSquad[client] = 0;

}
public Action:Command_BotCount(client, args) {
	/*
	new iBotCount, iAliveBots;
	for (new i = 1; i <= MaxClients; i++)
    {
		if (i > 0 && IsClientInGame(i) && IsFakeClient(i))
    	{
			iBotCount++
			if (IsPlayerAlive(i))
				iAliveBots++;
		}
	}
	
	PrintToChat(client, "[CoopBot] Bot total: %d / Alive bots: %d", iBotCount, iAliveBots); // show chat debug 
	*/
	new mc = GetMaxClients();
	for( new i = 1; i < mc; i++ ){
		//if( IsClientInGame(i) && IsFakeClient(i)){
		if(IsClientInGame(i) && IsClientConnected(i)){
			decl String:target_name[50];
			GetClientName(i, target_name, sizeof(target_name));
			
			if (StrContains(target_name, g_sSecBot, false) >= 0)
			{
				//KickClient(i);
			}
		}
	}
	
	return Plugin_Handled;
}

public CvarChange(Handle:cvar, const String:oldvalue[], const String:newvalue[])
{
	g_iRoundEndBlockEnabled = GetConVarInt(sm_roundendblock_enabled);
	g_iRoundEndBlockTimes = GetConVarInt(sm_roundendblock_times);
	g_iRoundEndBlockReviveDelay = GetConVarInt(sm_roundendblock_revive_delay);
	g_iRoundEndBlockResetRound = GetConVarInt(sm_roundendblock_reset_each_round);
	g_iRoundEndBlockDebug = GetConVarInt(sm_roundendblock_debug);
}
// When player picked squad, initialize variables
public Action:Event_PlayerPickSquad_Post( Handle:event, const String:name[], bool:dontBroadcast )
{

	new client = GetClientOfUserId( GetEventInt( event, "userid" ) );
	
	if( client == 0 || !IsClientInGame(client) || IsFakeClient(client))
		return;	
	// Init variable
	playerPickSquad[client] = 1;

}
public Action:Event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	// Reset respawn position
	g_fSpawnPoint[0] = 0.0;
	g_fSpawnPoint[1] = 0.0;
	g_fSpawnPoint[2] = 0.0;
	
	g_iIsRoundStarted = 1;
	g_iIsRoundStartedPost = 0;
	g_iRoundStatus = 0;
	if (g_iRoundEndBlockResetRound == 1)
		g_iRoundBlockCount = g_iRoundEndBlockTimes;
	
	new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");

	if (ncp < 6)
	{
		if (g_iRoundBlockCount > 1)
			g_iRoundBlockCount = 1;
	}
	//KickBlockerClient();
	if (g_iRoundEndBlockDebug)
	{
		PrintToServer("[RndEndBlock] Round started.");
	}
	
	new iPreRound = GetConVarInt(FindConVar("mp_timer_preround"));
	CreateTimer(float(iPreRound) , Timer_RoundStartPost);
}
public Action:Timer_RoundStartPost(Handle:Timer)
{
	if (g_iRoundEndBlockDebug)
	{
		PrintToServer("[RndEndBlock] Round post started.");
	}
	
	g_iRoundStatus = 1;
	g_iIsRoundStartedPost = 1;
}
public Action:Event_RoundEnd_Pre(Handle:event, const String:name[], bool:dontBroadcast)
{
	// Kick blocker client
	//KickBlockerClient();
	//KickBlocker(); //Just resets cvars now
	// Reset respawn position
	g_fSpawnPoint[0] = 0.0;
	g_fSpawnPoint[1] = 0.0;
	g_fSpawnPoint[2] = 0.0;
	
	g_iIsRoundStarted = 0;
	g_iIsRoundStartedPost = 0;
	g_iRoundStatus = 0;

	if (g_iRoundEndBlockDebug)
	{
		PrintToServer("[RndEndBlock] Round ended.");
	}
}
public Action:Event_RoundEnd_Post(Handle:event, const String:name[], bool:dontBroadcast)
{
	// Kick blocker client
	//KickBlockerClient();
	//KickBlocker(); //Just resets cvars now
	// Reset respawn position
	g_fSpawnPoint[0] = 0.0;
	g_fSpawnPoint[1] = 0.0;
	g_fSpawnPoint[2] = 0.0;
	
	g_iIsRoundStarted = 0;
	g_iIsRoundStartedPost = 0;
	g_iRoundStatus = 0;

	if (g_iRoundEndBlockResetRound == 1)
		g_iRoundBlockCount = g_iRoundEndBlockTimes;
	
	new ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");

	if (ncp < 6)
	{
		if (g_iRoundBlockCount > 1)
			g_iRoundBlockCount = 1;
	}
	if (g_iRoundEndBlockDebug)
	{
		PrintToServer("[RndEndBlock] Round ended.");
	}
}

public Action:Event_GameStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	g_iIsGameEnded = 0;
}
public Action:Event_GameEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
	g_iIsGameEnded = 1;
}
public Action:Event_ObjectDestroyed_Post(Handle:event, const String:name[], bool:dontBroadcast)
{
	// g_iRoundEndBlockCapCount++; 
	// if (g_iRoundEndBlockMaxCapPoints > g_iRoundEndBlockMaxCapPoints)
	// {
	// 	PrintToChatAll("[RndEndBlock] Round Save Earned due to capturing %d objectives", g_iRoundEndBlockMaxCapPoints);
	// 	g_iRoundEndBlockCapCount = 0;
	// 	if (g_iRoundEndBlockResetRound == 1 && g_iRoundBlockCount < 1)
	// 		g_iRoundBlockCount++;
	// }
	new attacker = GetEventInt(event, "attacker");

	if (attacker > 0 && IsValidClient(attacker))
	{
		new Float:attackerPos[3];
		GetClientAbsOrigin(attacker, Float:attackerPos);
		g_fSpawnPoint = attackerPos;
		
		if (g_iRoundEndBlockDebug)
		{
			PrintToServer("[RndEndBlock] Spawnpoint updated. (Object destroyed)");
		}
	}

	
	return Plugin_Continue;
}
public Action:Event_ControlPointCaptured_Pre(Handle:event, const String:name[], bool:dontBroadcast)
{
	new iTeam = GetEventInt(event, "team");
	
	if ((Ins_InCounterAttack()) && iTeam == 3)
	{	
		if (g_iRoundEndBlockDebug)
		{
			PrintToServer("[RndEndBlock] Counter-attack capturing protected.");
		}
		
		// Call counter-attack end timer
		if (!g_bIsCounterAttackTimerActive)
		{
			g_bIsCounterAttackTimerActive = true;
			CreateTimer(1.0, Timer_CounterAttackEnd, _, TIMER_REPEAT);
			//PrintToServer("[RESPAWN] Counter-attack timer started. (Normal counter-attack)");
		}
		return Plugin_Stop;
	}
	
	return Plugin_Continue;
}

// When counter-attack end, reset reinforcement time
public Action:Timer_CounterAttackEnd(Handle:Timer)
{
	// If round end, exit
	if (g_iRoundStatus == 0)
	{
		g_bIsCounterAttackTimerActive = false;
		return Plugin_Stop;
	}
	
	// Checkpoint
	// Check counter-attack end
	if (!Ins_InCounterAttack())
	{
		
		//PrintToServer("[RndEndBlock] Counter-attack is over.");
		
		g_bIsCounterAttackTimerActive = false;
		return Plugin_Stop;
	}
	
	return Plugin_Continue;
}
public Action:Event_ControlPointCaptured_Post(Handle:event, const String:name[], bool:dontBroadcast)
{
	decl String:cappers[256];
	GetEventString(event, "cappers", cappers, sizeof(cappers));
	// g_iRoundEndBlockCapCount++; 
	// if (g_iRoundEndBlockMaxCapPoints > g_iRoundEndBlockMaxCapPoints)
	// {
	// 	PrintToChatAll("[RndEndBlock] Round Save Earned due to capturing %d objectives", g_iRoundEndBlockMaxCapPoints);
	// 	g_iRoundEndBlockCapCount = 0;
	// 	if (g_iRoundEndBlockResetRound == 1 && g_iRoundBlockCount < 1)
	// 		g_iRoundBlockCount++;
	// }
	new cappersLength = strlen(cappers);
	for (new i = 0 ; i < cappersLength; i++)
	{
		new clientCapper = cappers[i];
		if(clientCapper > 0 && IsClientInGame(clientCapper) && IsValidClient(clientCapper) && IsPlayerAlive(clientCapper) && !IsFakeClient(clientCapper))
		{
			new Float:capperPos[3];
			GetClientAbsOrigin(clientCapper, Float:capperPos);

			g_fSpawnPoint = capperPos;
			
			if (g_iRoundEndBlockDebug)
			{
				PrintToServer("[RndEndBlock] Spawnpoint updated. (Control point captured)");
			}
			
			break;
		}
	}
	
}

public Action:Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	 //new client = GetClientOfUserId(GetEventInt(event, "userid"));
	
	// if (client > 0 && IsClientConnected(client) && IsClientInGame(client))
	// {
	// 	new iTeam = GetClientTeam(client);
	// 	if(client == g_iSecBotID && iTeam == TEAM_1){
	// 		hideBot(client);
			
	// 		if (g_fSpawnPoint[0] != 0.0 && g_fSpawnPoint[1] != 0.0 && g_fSpawnPoint[2] != 0.0)
	// 		{
	// 			TeleportEntity(g_iSecBotID, g_fSpawnPoint, NULL_VECTOR, NULL_VECTOR);
	// 			if (g_iRoundEndBlockDebug)
	// 			{
	// 				PrintToServer("[RndEndBlock] Blocker bot teleported.");
	// 			}
	// 		}
	// 	}
	// 	else if (!IsFakeClient(client))
	// 	{
	// 		KickBlockerClient();
	// 	}
	// }

}

// When player disconnected server, intialize variables
public Action:Event_PlayerDisconnect(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client > 0 && IsClientInGame(client))
	{
	
		playerPickSquad[client] = 0;
	}
	return Plugin_Continue;
}

public Action:Event_PlayerDeathPre(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (g_iRoundEndBlockEnabled == 0)
		return Plugin_Continue;
	new teamSecCount = GetSecTeamBotCount();
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client > 0 && IsClientConnected(client) && IsClientInGame(client) && !IsFakeClient(client))
	{
		if (g_iIsRoundStarted == 1 && g_iIsRoundStartedPost == 1 && g_iIsGameEnded == 0)
		{
			//new iRemainingLife = GetRemainingLife();
			new iAlivePlayers = GetAlivePlayers();
			new iAliveAllowed = 5;
			if (teamSecCount <= 6)
				iAliveAllowed = 1;
			if (teamSecCount > 6 && teamSecCount <= 10)
				iAliveAllowed = 2;
			else
				iAliveAllowed = GetRandomInt(1, 5);


			if (iAlivePlayers < iAliveAllowed && g_iRoundBlockCount > 0)
			{
				//AddBlocker();
				g_iRoundBlockCount--;
				
				decl String:textToPrint[64];
				decl String:textToHint[64];
				Format(textToPrint, sizeof(textToPrint), "\x03[Server] RoundEnd is protected. (Remaining Saves: %d)", g_iRoundBlockCount);
				Format(textToHint, sizeof(textToHint), "RoundEnd is protected. | Remaining Saves: %d", g_iRoundBlockCount);
				PrintToChatAll(textToPrint);
				PrintHintTextToAll(textToHint);
				//ShowPanelAll(textToHint);
				
				g_iReviveCount = g_iRoundEndBlockReviveDelay;
				// if (g_iAnnounceActive == 0)
				// {
				// 	g_iAnnounceActive = 1;
				// 	g_iReviveCount = g_iRoundEndBlockReviveDelay;
				// 	CreateTimer(1.0, Timer_Announce, _, TIMER_REPEAT);
				// }
				
				if (Ins_InCounterAttack())
				{
					// Get capture point speed cvar values
					g_iCPSpeedUp = GetConVarInt(g_hCvarCPSpeedUp);
					g_iCPSpeedUpMax = GetConVarInt(g_hCvarCPSpeedUpMax);
					g_iCPSpeedUpRate = GetConVarInt(g_hCvarCPSpeedUpRate);
					
					// Prevent round end
					SetConVarInt(g_hCvarCPSpeedUp, -1, true, false);
					SetConVarInt(g_hCvarCPSpeedUpMax, 0, true, false);
					SetConVarInt(g_hCvarCPSpeedUpRate, 0, true, false);
				}
				RevivePlayers();
			}
			else if (iAlivePlayers == 1 && g_iRoundBlockCount <= 0)
			{
				decl String:textToPrint[64];
				decl String:textToHint[64];
				Format(textToPrint, sizeof(textToPrint), "\x03[Server] There's no more RoundEnd protection.");
				Format(textToHint, sizeof(textToHint), "There's no more RoundEnd protection.");
				PrintToChatAll(textToPrint);
				PrintHintTextToAll(textToHint);
				//ShowPanelAll(textToHint);
			}
		}
	}
	
	return Plugin_Continue;
}
public Action:Timer_Announce(Handle:Timer)
{
	if (g_iIsGameEnded == 0 && g_iIsRoundStarted == 1 && g_iIsRoundStartedPost == 1 && g_iSecBotID > 0)
	{
		if (g_iReviveCount >= 0)
		{
			for (new client = 1; client <= MaxClients; client++)
			{
				if (IsClientConnected(client) && !IsFakeClient(client))
				{
					new Handle:hPanel = CreatePanel(INVALID_HANDLE);
					decl String:buffer[128];
					
					SetPanelTitle(hPanel, "RoundEnd Protection");
					DrawPanelItem(hPanel, "", ITEMDRAW_SPACER);
					
					DrawPanelItem(hPanel, "Waiting to revive players.", ITEMDRAW_DEFAULT);
					//DrawPanelText(hPanel, "Waiting for reviving player.");
					DrawPanelItem(hPanel, "", ITEMDRAW_SPACER);
					
					Format(buffer, sizeof(buffer), "Team Reinforcement arrives in: %d", g_iReviveCount);
					DrawPanelItem(hPanel, buffer, ITEMDRAW_DEFAULT);
					//DrawPanelText(hPanel, buffer);
					
					Format(buffer, sizeof(buffer), "Team Reinforcements remaining: %d", g_iRoundBlockCount);
					DrawPanelItem(hPanel, buffer, ITEMDRAW_DEFAULT);
					//DrawPanelText(hPanel, buffer);
					
					SetPanelCurrentKey(hPanel, 10);
					SendPanelToClient(hPanel, client, NullMenuHandler, 1);
					CloseHandle(hPanel);
				}
			}
			g_iReviveCount--;
		}
		else
		{
			RevivePlayers();
			g_iAnnounceActive = 0;
			return Plugin_Stop;
		}
	}
	else
	{
		g_iAnnounceActive = 0;
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

void ShowPanel(iTarget, String:sMessage[], iShowTime = 5)
{
	new Handle:hPanel = CreatePanel(INVALID_HANDLE);
	DrawPanelText(hPanel, sMessage);
	SendPanelToClient(hPanel, iTarget, NullMenuHandler, iShowTime);
	CloseHandle(hPanel);
}
void ShowPanelAll(String:sMessage[])
{
	for (new client = 1; client <= MaxClients; client++)
    {
		if (client > 0 && IsClientConnected(client) && IsClientInGame(client) && !IsFakeClient(client))
		{
			ShowPanel(client, sMessage);
		}
	}
}
public NullMenuHandler(Handle:menu, MenuAction:action, param1, param2) {}

void AddBlocker() {
	// if (g_iSecBotID > 0)
	// {
	// 	if (g_iRoundEndBlockDebug)
	// 	{	
	// 		PrintToServer("[RndEndBlock] Blocker bot already exists.");
	// 	}
	// 	return;
	// }
	
	// //KickBlocker();
	// //g_iSecBotID = CreateFakeClient(g_sSecBot);
	
	// if (g_iSecBotID > 0)
	// {
	// 	ChangeClientTeam(g_iSecBotID, TEAM_1);
	// 	SDKCall(g_hPlayerRespawn, g_iSecBotID);
	// 	SetEntProp(g_iSecBotID, Prop_Data, "m_iFrags", g_iScore);
		
	// 	if (g_iRoundEndBlockDebug)
	// 	{
	// 		PrintToServer("[RndEndBlock] Added RoundEnd Blocker.");
	// 	}
	// }
	//else
	//	PrintToServer("[RndEndBlock] Failed to adding RoundEnd Blocker.");
	
	// new Handle:hCvar = INVALID_HANDLE;
	// hCvar = FindConVar("mp_forcecamera");
	// SetConVarInt(hCvar, 0, true, false);
	// hCvar = FindConVar("ins_deadcam_modes");
	// SetConVarInt(hCvar, 1, true, false);
	
	
	return;
}
void KickBlockerClient() {
	// if (g_iSecBotID > 0)
	// {
	// 	KickClient(g_iSecBotID);
	// 	if (g_iRoundEndBlockDebug)
	// 	{
	// 		PrintToServer("[RndEndBlock] Kicked RoundEnd Blocker. (Name: %N / ID: %d)", g_iSecBotID, g_iSecBotID);
	// 	}
	// 	g_iSecBotID = 0;
	// }
	// else
	// {
	// 	KickBlocker();
	// }
	
	// //Restore capture point speed up cvars
	// if (Ins_InCounterAttack())
	// {
	// 	SetConVarInt(g_hCvarCPSpeedUp, g_iCPSpeedUp, true, false);
	// 	SetConVarInt(g_hCvarCPSpeedUpMax, g_iCPSpeedUpMax, true, false);
	// 	SetConVarInt(g_hCvarCPSpeedUpRate, g_iCPSpeedUpRate, true, false);
	// }
}
void KickBlocker() {
	// new mc = GetMaxClients();
	// for( new i = 1; i < mc; i++ ){
	// 	if(IsClientInGame(i) && IsClientConnected(i) && IsFakeClient(i)){
	// 		decl String:target_name[50];
	// 		GetClientName(i, target_name, sizeof(target_name));
	// 		if (StrContains(target_name, g_sSecBot, false) >= 0)
	// 		{ 
	// 			KickClient(i);
	// 			if (g_iRoundEndBlockDebug)
	// 			{
	// 				PrintToServer("[RndEndBlock] Kicked RoundEnd Blocker. Method_2 (Name: %N / ID: %d)", i, i); // show chat debug 
	// 			} 
	// 		}
	// 	}
	// }
	
	// new Handle:hCvar = INVALID_HANDLE;
	// hCvar = FindConVar("mp_forcecamera");
	// SetConVarInt(hCvar, 1, true, false);
	// hCvar = FindConVar("ins_deadcam_modes");
	// SetConVarInt(hCvar, 0, true, false);
	// g_iSecBotID = 0;
	
	/*
	if (g_iSecBotID > 0)
	{
		KickClient(g_iSecBotID);
		g_iSecBotID = -1;
		g_iIsActiveBlocking = 0;
		
		new Handle:hCvar = INVALID_HANDLE;
		hCvar = FindConVar("mp_forcecamera");
		SetConVarInt(hCvar, 1);
		
		PrintToServer("[RndEndBlock] Kicked blocker bot."); // show chat debug 
	}
	else
	{
		PrintToServer("[RndEndBlock] Blocker bot does not exist."); // show chat debug 
	}
	*/
}
void RevivePlayers()
{
	if (GetRealClientCount() <= 0) return;
	static iIsReviving = 0;
	
	if (iIsReviving == 1)
		return;
	else
		iIsReviving = 1;
	
	for (new client = 1; client <= MaxClients; client++)
    {
		if (client > 0 && IsClientConnected(client) && IsClientInGame(client) && !IsFakeClient(client) && !IsPlayerAlive(client))
		{
			new iTeam = GetClientTeam(client);
			if (iTeam == TEAM_1 && playerPickSquad[client] == 1)
			{
				SDKCall(g_hPlayerRespawn, client);
			
				if (g_fSpawnPoint[0] != 0.0 && g_fSpawnPoint[1] != 0.0 && g_fSpawnPoint[2] != 0.0)
					TeleportEntity(client, g_fSpawnPoint, NULL_VECTOR, NULL_VECTOR);

				// Get dead body
				new clientRagdoll = GetEntPropEnt(client, Prop_Send, "m_hRagdoll");
				
				new primaryRemove = 0;
				new secondaryRemove = 0; 
				new grenadesRemove = 1;
				RemoveWeapons(client, primaryRemove, secondaryRemove, grenadesRemove);
				//This timer safely removes client-side ragdoll
				if(clientRagdoll > 0 && IsValidEdict(clientRagdoll) && IsValidEntity(clientRagdoll))
				{
					// Get dead body's entity
					new ref = EntIndexToEntRef(clientRagdoll);
					new entity = EntRefToEntIndex(ref);
					if(entity != INVALID_ENT_REFERENCE && IsValidEntity(entity))
					{
						// Remove dead body's entity
						AcceptEntityInput(entity, "Kill");
						clientRagdoll = INVALID_ENT_REFERENCE;
					}
				}
			}
		}
	}
	iIsReviving = 0;
	if (g_iRoundEndBlockDebug)
	{
		PrintToServer("[RndEndBlock] All players are revived.");
	}
}
// public Action:CreatBots(Handle:timer){
// 	CreateFakeClient(g_sSecBot);
// 	botSwitch();
// }
// void botSwitch(){
// 	new mc = GetMaxClients();
// 	for( new i = 1; i < mc; i++ ){
// 		if( IsClientInGame(i) && IsFakeClient(i)){
// 			decl String:target_name[50];
// 			GetClientName( i, target_name, sizeof(target_name));
// 			//if(StrEqual(target_name, g_sSecBot)){
// 			if (StrContains(target_name, g_sSecBot, false) >= 0)
// 			{
// 				g_iSecBotID = i;
// 				ChangeClientTeam(i, TEAM_1);
// 				SDKCall(g_hPlayerRespawn, i);
// 				SetEntProp(i, Prop_Data, "m_iFrags", g_iScore);
				
// 				break;
// 			}
// 		}
// 	}
// }
stock GetRemainingLife()
{
	new Handle:hCvar = INVALID_HANDLE;
	new iRemainingLife;
	hCvar = FindConVar("sm_remaininglife");
	iRemainingLife = GetConVarInt(hCvar);
	
	return iRemainingLife;
}
stock GetSecTeamBotCount()
{
	new iTeam, iSecTeamCount;
	for (new client = 1; client <= MaxClients; client++)
    {
		if (client > 0 && IsClientInGame(client) && IsFakeClient(client) && IsFakeClient(client))
		{
			iTeam = GetClientTeam(client);
			if (iTeam == TEAM_1) iSecTeamCount++
		}
	}
	
	return iSecTeamCount;
}
stock GetRealClientCount( bool:inGameOnly = true ) {
	new clients = 0;
	new iTeam;
	for( new i = 1; i <= GetMaxClients(); i++ ) {
		if(((inGameOnly) ? IsClientInGame(i) : IsClientConnected(i) ) && !IsFakeClient(i)) {
			iTeam = GetClientTeam(i);
			if (iTeam == TEAM_1) clients++;
		}
	}
	return clients;
}
stock GetAlivePlayers() {
	new iCount = 0;
	for (new client = 1; client <= MaxClients; client++)
    {
		if (client > 0 && IsClientConnected(client) && IsClientInGame(client) && !IsFakeClient(client) && IsPlayerAlive(client))
		{
			iCount++;
		}
	}
	return iCount;
}
public hideBot(any:client){
	SetEntProp(client, Prop_Data, "m_takedamage", 0, 1);
	SetEntData(client, g_iCollOff, 2, 4, true);
	set_rendering(client, g_Effect, 0, 0, 0, g_Render, 0);
	/*
	new Float:loc[3];
	loc[0] = 10000.0;
	loc[1] = 10000.0;
	loc[2] = 10000.0;
	TeleportEntity(client, loc, NULL_VECTOR, NULL_VECTOR);
	*/
	
	if (g_iRoundEndBlockDebug)
	{
		PrintToServer("[RndEndBlock] Hided RoundEnd Blocker (Name: %N / ID: %d)", client, client);
	}
}
stock set_rendering(index, FX:fx=FxNone, r=255, g=255, b=255, Render:render=Normal, amount=255)
{
	SetEntProp(index, Prop_Send, "m_nRenderFX", _:fx, 1);
	SetEntProp(index, Prop_Send, "m_nRenderMode", _:render, 1);

	new offset = GetEntSendPropOffs(index, "m_clrRender");
	
	SetEntData(index, offset, r, 1, true);
	SetEntData(index, offset + 1, g, 1, true);
	SetEntData(index, offset + 2, b, 1, true);
	SetEntData(index, offset + 3, amount, 1, true);
}

//Respawn Script Specific
public RemoveWeapons(client, primaryRemove, secondaryRemove, grenadesRemove)
{

	new primaryWeapon = GetPlayerWeaponSlot(client, 0);
	new secondaryWeapon = GetPlayerWeaponSlot(client, 1);
	new playerGrenades = GetPlayerWeaponSlot(client, 3);

	// Check and remove primaryWeapon
	if (primaryWeapon != -1 && IsValidEntity(primaryWeapon) && primaryRemove == 1) // We need to figure out what slots are defined#define Slot_HEgrenade 11, #define Slot_Flashbang 12, #define Slot_Smokegrenade 13
	{
		// Remove primaryWeapon
		decl String:weapon[32];
		GetEntityClassname(primaryWeapon, weapon, sizeof(weapon));
		RemovePlayerItem(client,primaryWeapon);
		AcceptEntityInput(primaryWeapon, "kill");
	}
	// Check and remove secondaryWeapon
	if (secondaryWeapon != -1 && IsValidEntity(secondaryWeapon) && secondaryRemove == 1) // We need to figure out what slots are defined#define Slot_HEgrenade 11, #define Slot_Flashbang 12, #define Slot_Smokegrenade 13
	{
		// Remove primaryWeapon
		decl String:weapon[32];
		GetEntityClassname(secondaryWeapon, weapon, sizeof(weapon));
		RemovePlayerItem(client,secondaryWeapon);
		AcceptEntityInput(secondaryWeapon, "kill");
	}
	// Check and remove grenades
	if (playerGrenades != -1 && IsValidEntity(playerGrenades) && grenadesRemove == 1) // We need to figure out what slots are defined#define Slot_HEgrenade 11, #define Slot_Flashbang 12, #define Slot_Smokegrenade 13
	{
		while (playerGrenades != -1 && IsValidEntity(playerGrenades)) // since we only have 3 slots in current theate
		{
			playerGrenades = GetPlayerWeaponSlot(client, 3);
			if (playerGrenades != -1 && IsValidEntity(playerGrenades)) // We need to figure out what slots are defined#define Slot_HEgrenade 11, #define Slot_Flashbang 12, #define Slot_Smokegrenade 1
			{
				// Remove grenades
				decl String:weapon[32];
				GetEntityClassname(playerGrenades, weapon, sizeof(weapon));
				RemovePlayerItem(client,playerGrenades);
				AcceptEntityInput(playerGrenades, "kill");
				
			}
		}
	}
}