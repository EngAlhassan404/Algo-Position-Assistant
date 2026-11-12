//+------------------------------------------------------------------+
//|                                Algo Position Assistant.mq5       |
//|                Copyright 2026, Eng.Alhassan Ali Mubarak Bahbah   |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Eng.Alhassan Ali Mubarak Bahbah"
#property link      ""
#property version   "3.00"
#property description "Interactive Position Management Assistant v3.00 - Instant One-Click Trade/Close & Configurable Shift SuperTrend Trailing"

#include <Trade\Trade.mqh>
#include <CSuperTrendEngine.mqh>

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_MANAGE_SCOPE
  {
   SCOPE_CURRENT_SYMBOL = 0, // Current Chart Symbol Only
   SCOPE_ALL_POSITIONS  = 1  // Any Open Position (Account-Wide)
  };

enum ENUM_MGMT_MODE
  {
   MGMT_SUPERTREND = 0       // SuperTrend Trailing Stop
   // Extensible: Add future management modes here (e.g., MGMT_BREAKEVEN, MGMT_ATR_TRAIL)
  };

enum ENUM_ST_SIGNAL_BAR
  {
   ST_BAR_CLOSED  = 1,       // Last Closed Candle (Shift 1)
   ST_BAR_CURRENT = 0        // Current Live Candle (Shift 0 - Default)
  };

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== SuperTrend Engine Settings ==="
input ENUM_TIMEFRAMES    InpSTTimeframe       = PERIOD_CURRENT;       // SuperTrend Timeframe
input int                InpSTAtrPeriod       = 10;                   // SuperTrend ATR Period
input double             InpSTMultiplier      = 3.0;                  // SuperTrend ATR Multiplier

input group "=== Trailing Stop & Broker Safety Settings ==="
input ENUM_ST_SIGNAL_BAR InpSTTrailBar        = ST_BAR_CURRENT;       // Trailing Stop Reference Candle (SL Only)
input bool               InpInitialTrailState = false;                // Initial Trailing State (Toggleable on Panel)
input ENUM_MANAGE_SCOPE  InpInitialScope      = SCOPE_CURRENT_SYMBOL; // Initial Scope (Toggleable on Panel)
input ulong              InpMagicFilter       = 0;                    // Magic Number Filter (0 = Adopt All Positions)
input int                InpMinStepPoints     = 1;                    // Minimum SL Update Step (Points)
input int                InpExtraStopBuffer   = 0;                    // Extra Safety Buffer over Broker StopsLevel (Points)

input group "=== One-Click Trading Defaults ==="
input double             InpDefaultLot        = 0.01;                 // Initial Lot Size (Clamped to Broker Min/Max)
input ulong              InpSlippagePoints    = 20;                   // Max Slippage / Deviation (Points)

input group "=== SuperTrend Chart Lines (No Canvas) ==="
input bool               InpShowSTLines       = true;                 // Show SuperTrend Lines on Chart
input int                InpSTDrawBars        = 250;                  // Number of Historical Bars to Draw
input color              InpSTUpColor         = clrLimeGreen;         // SuperTrend Bullish Color (Closed Candle Above)
input color              InpSTDownColor       = clrRed;               // SuperTrend Bearish Color (Closed Candle Below)
input int                InpSTLineWidth       = 2;                    // SuperTrend Line Width

input group "=== Control Panel Position ==="
input int                InpPanelX            = 20;                   // Initial Panel X Position
input int                InpPanelY            = 35;                   // Initial Panel Y Position

//+------------------------------------------------------------------+
//| Symbol Engine Pool (Supports Multi-Symbol "Any Position" Mode)   |
//+------------------------------------------------------------------+
struct SymbolEngineEntry
  {
   string             symbol;
   CSuperTrendEngine *engine;
  };

class CSymbolSuperTrendPool
  {
private:
   SymbolEngineEntry  m_entries[];
   ENUM_TIMEFRAMES    m_timeframe;
   int                m_atrPeriod;
   double             m_multiplier;

public:
                      CSymbolSuperTrendPool(void) : m_timeframe(PERIOD_CURRENT), m_atrPeriod(10), m_multiplier(3.0) {}
                     ~CSymbolSuperTrendPool(void) { ReleaseAll(); }

   void               Configure(ENUM_TIMEFRAMES tf, int atrPeriod, double multiplier)
     {
      m_timeframe  = tf;
      m_atrPeriod  = atrPeriod;
      m_multiplier = multiplier;
     }

   CSuperTrendEngine *GetEngine(const string symbol)
     {
      int total = ArraySize(m_entries);
      for(int i = 0; i < total; i++)
        {
         if(m_entries[i].symbol == symbol && m_entries[i].engine != NULL)
            return m_entries[i].engine;
        }

      CSuperTrendEngine *newEngine = new CSuperTrendEngine();
      if(newEngine == NULL)
         return NULL;

      if(!newEngine.Init(symbol, m_timeframe, m_atrPeriod, m_multiplier))
        {
         delete newEngine;
         return NULL;
        }

      ArrayResize(m_entries, total + 1);
      m_entries[total].symbol = symbol;
      m_entries[total].engine = newEngine;
      return newEngine;
     }

   void               ReleaseAll(void)
     {
      int total = ArraySize(m_entries);
      for(int i = 0; i < total; i++)
        {
         if(m_entries[i].engine != NULL)
           {
            m_entries[i].engine.Release();
            delete m_entries[i].engine;
            m_entries[i].engine = NULL;
           }
        }
      ArrayResize(m_entries, 0);
     }
  };

//+------------------------------------------------------------------+
//| Abstract Position Management Interface (Extensible Architecture) |
//+------------------------------------------------------------------+
class CPositionManagerBase
  {
protected:
   CTrade            m_trade;
   ulong             m_magicFilter;
   int               m_minStepPoints;
   int               m_extraStopBuffer;
   string            m_lastActionMsg;

public:
                     CPositionManagerBase(void) : m_magicFilter(0), m_minStepPoints(1), m_extraStopBuffer(0), m_lastActionMsg("") {}
   virtual          ~CPositionManagerBase(void) {}

   void              ConfigureBase(ulong magicFilter, int minStepPoints, int extraStopBuffer, ulong deviation)
     {
      m_magicFilter     = magicFilter;
      m_minStepPoints   = MathMax(1, minStepPoints);
      m_extraStopBuffer = MathMax(0, extraStopBuffer);
      m_trade.SetDeviationInPoints(deviation);
      m_trade.SetAsyncMode(false);
     }

   string            GetLastActionMessage(void) const { return m_lastActionMsg; }

   virtual string    GetStrategyName(void) const = 0;
   virtual bool      ManagePosition(ulong ticket) = 0;
   virtual void      Release(void) {}
  };

//+------------------------------------------------------------------+
//| SuperTrend Trailing Stop Manager (Uses InpSTTrailBar Shift Only) |
//+------------------------------------------------------------------+
class CSuperTrendPositionManager : public CPositionManagerBase
  {
private:
   CSymbolSuperTrendPool m_enginePool;
   int                   m_trailShift;

public:
                     CSuperTrendPositionManager(void) : m_trailShift(0) {}
   virtual          ~CSuperTrendPositionManager(void) { Release(); }

   void              ConfigureSuperTrend(ENUM_TIMEFRAMES tf, int atrPeriod, double multiplier, ENUM_ST_SIGNAL_BAR trailBar)
     {
      m_trailShift = (trailBar == ST_BAR_CLOSED) ? 1 : 0;
      m_enginePool.Configure(tf, atrPeriod, multiplier);
     }

   virtual string    GetStrategyName(void) const
     {
      return StringFormat("SuperTrend (Sh.%d)", m_trailShift);
     }

   virtual void      Release(void)
     {
      m_enginePool.ReleaseAll();
     }

   virtual bool      ManagePosition(ulong ticket)
     {
      if(!PositionSelectByTicket(ticket))
         return false;

      // Optional Magic Number filter (0 = adopt all open positions)
      if(m_magicFilter > 0)
        {
         ulong posMagic = (ulong)PositionGetInteger(POSITION_MAGIC);
         if(posMagic != m_magicFilter)
            return false;
        }

      string posSymbol = PositionGetString(POSITION_SYMBOL);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      if(posType != POSITION_TYPE_BUY && posType != POSITION_TYPE_SELL)
         return false;

      CSuperTrendEngine *engine = m_enginePool.GetEngine(posSymbol);
      if(engine == NULL)
         return false;

      // Trailing stop uses m_trailShift (Default: 0 = Live Candle, 1 = Last Closed Candle)
      double rawTargetSL = engine.GetStopLossPrice(m_trailShift, posType);
      if(rawTargetSL <= 0.0 || !MathIsValidNumber(rawTargetSL))
         return false;

      int    digits      = (int)SymbolInfoInteger(posSymbol, SYMBOL_DIGITS);
      double point       = SymbolInfoDouble(posSymbol, SYMBOL_POINT);
      long   stopsLevel  = SymbolInfoInteger(posSymbol, SYMBOL_TRADE_STOPS_LEVEL);
      long   freezeLevel = SymbolInfoInteger(posSymbol, SYMBOL_TRADE_FREEZE_LEVEL);
      double bid         = SymbolInfoDouble(posSymbol, SYMBOL_BID);
      double ask         = SymbolInfoDouble(posSymbol, SYMBOL_ASK);

      if(point <= 0.0 || bid <= 0.0 || ask <= 0.0)
         return false;

      double targetSL    = NormalizeDouble(rawTargetSL, digits);
      double minStopDist = (double)(stopsLevel + m_extraStopBuffer) * point;
      double freezeDist  = (double)freezeLevel * point;
      double minStepDist = (double)m_minStepPoints * point;

      // BUY Position: SL trails UPWARD below Bid using lower SuperTrend band
      if(posType == POSITION_TYPE_BUY)
        {
         if(currentSL > 0.0 && freezeDist > 0.0 && (bid - currentSL) <= freezeDist)
            return false;

         if((bid - targetSL) < minStopDist)
            return false;

         // Only tighten SL upward; never move SL downward
         if(currentSL > 0.0 && targetSL <= (currentSL + minStepDist))
            return false;

         if(m_trade.PositionModify(ticket, targetSL, currentTP))
           {
            m_lastActionMsg = StringFormat("SL Updated #%I64u (%s) -> %s", ticket, posSymbol, DoubleToString(targetSL, digits));
            return true;
           }
        }
      // SELL Position: SL trails DOWNWARD above Ask using upper SuperTrend band
      else if(posType == POSITION_TYPE_SELL)
        {
         if(currentSL > 0.0 && freezeDist > 0.0 && (currentSL - ask) <= freezeDist)
            return false;

         if((targetSL - ask) < minStopDist)
            return false;

         // Only tighten SL downward; never move SL upward
         if(currentSL > 0.0 && targetSL >= (currentSL - minStepDist))
            return false;

         if(m_trade.PositionModify(ticket, targetSL, currentTP))
           {
            m_lastActionMsg = StringFormat("SL Updated #%I64u (%s) -> %s", ticket, posSymbol, DoubleToString(targetSL, digits));
            return true;
           }
        }

      return false;
     }
  };

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
string                     g_Prefix          = "STPA3_";
int                        g_PanelX          = 20;
int                        g_PanelY          = 35;
int                        g_PanelWidth      = 310;
int                        g_PanelHeight     = 292;
int                        g_HeaderHeight    = 28;
bool                       g_IsCollapsed     = false;
bool                       g_IsDragging      = false;
int                        g_DragOffsetX     = 0;
int                        g_DragOffsetY     = 0;

// Interactive State
bool                       g_TrailingEnabled = false;
ENUM_MANAGE_SCOPE          g_ManageScope     = SCOPE_CURRENT_SYMBOL;
ENUM_MGMT_MODE             g_MgmtMode        = MGMT_SUPERTREND;

// Click Debounce & Status Hold State
ulong                      g_LastClickMs     = 0;
ulong                      g_StatusHoldUntil = 0;

// Cached UI Values (Prevent redundant per-tick object redraws that drop clicks)
string                     g_PrevBidMain     = "";
string                     g_PrevBidPips     = "";
string                     g_PrevBidPipe     = "";
string                     g_PrevAskMain     = "";
string                     g_PrevAskPips     = "";
string                     g_PrevAskPipe     = "";
string                     g_PrevStatusText  = "";
color                      g_PrevStatusColor = clrNONE;
int                        g_PrevCloseCount  = -1;
ENUM_MANAGE_SCOPE          g_PrevCloseScope  = (ENUM_MANAGE_SCOPE)-1;

// One-Click Volume Limits & State
double                     g_VolMin          = 0.01;
double                     g_VolMax          = 100.0;
double                     g_VolStep         = 0.01;
double                     g_CurrentLot      = 0.01;

// Trade Execution & Management Objects
CTrade                     g_OrderTrade;
CSuperTrendPositionManager g_STManager;
CPositionManagerBase      *g_ActiveManager   = NULL;

// Chart Visualization SuperTrend Engine & Cache
CSuperTrendEngine          g_ChartSTEngine;
double                     g_CacheSTVal[];
int                        g_CacheSTDir[];
datetime                   g_CacheSTTime[];
datetime                   g_LastSTBarTime   = 0;
int                        g_LastDrawnBars   = 0;

// Panel Body Object List for Clean Collapse/Expand
string                     g_BodyObjects[];

//+------------------------------------------------------------------+
//| Helper: Check if Pixel Coordinate Lies Inside a Control Rect     |
//+------------------------------------------------------------------+
bool PointInRect(int px, int py, int rx, int ry, int rw, int rh)
  {
   return (px >= rx && px <= (rx + rw) && py >= ry && py <= (ry + rh));
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_PanelX          = InpPanelX;
   g_PanelY          = InpPanelY;
   g_TrailingEnabled = InpInitialTrailState;
   g_ManageScope     = InpInitialScope;
   g_MgmtMode        = MGMT_SUPERTREND;

   g_PrevBidMain = ""; g_PrevBidPips = ""; g_PrevBidPipe = "";
   g_PrevAskMain = ""; g_PrevAskPips = ""; g_PrevAskPipe = "";
   g_PrevStatusText = ""; g_PrevStatusColor = clrNONE;
   g_PrevCloseCount = -1; g_PrevCloseScope = (ENUM_MANAGE_SCOPE)-1;

   InitVolumeConstraints();

   g_OrderTrade.SetDeviationInPoints(InpSlippagePoints);
   g_OrderTrade.SetAsyncMode(false);
   ConfigureBestFillingMode(g_OrderTrade, _Symbol);

   // Configure Position Manager (Trailing Stop uses InpSTTrailBar: Shift 0 default or Shift 1)
   g_STManager.ConfigureBase(InpMagicFilter, InpMinStepPoints, InpExtraStopBuffer, InpSlippagePoints);
   g_STManager.ConfigureSuperTrend(InpSTTimeframe, InpSTAtrPeriod, InpSTMultiplier, InpSTTrailBar);
   g_ActiveManager = &g_STManager;

   // Initialize Chart SuperTrend Visual Engine (Direction/Color ALWAYS flips on Shift 1 Closed Candle)
   if(!g_ChartSTEngine.Init(_Symbol, InpSTTimeframe, InpSTAtrPeriod, InpSTMultiplier))
     {
      Print("Error: Failed to initialize CSuperTrendEngine for chart visualization.");
      return(INIT_FAILED);
     }

   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);

   ClampPanelToChart();
   CreateDashboard();
   UpdateLiveQuotes();
   UpdateSuperTrendChartLines(true);

   if(g_TrailingEnabled)
      ProcessOpenPositions();

   int initCount = CountEligiblePositions();
   RefreshCloseButton(initCount, true);
   UpdateStatusLine(initCount, true);
   ChartRedraw(0);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_ChartSTEngine.Release();
   if(g_ActiveManager != NULL)
      g_ActiveManager.Release();

   ObjectsDeleteAll(0, g_Prefix);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. Update Live Bid/Ask Quotes (Only updates changed text elements)
   UpdateLiveQuotes();

   // 2. Update SuperTrend Chart Line (Direction/Color confirmed strictly by Shift 1 closed bar)
   UpdateSuperTrendChartLines(false);

   // 3. Trail Stop Loss using configured InpSTTrailBar when Trailing Stop is Enabled
   int managedCount = CountEligiblePositions();
   if(g_TrailingEnabled && g_ActiveManager != NULL)
     {
      ProcessOpenPositions();
      managedCount = CountEligiblePositions();
     }

   RefreshCloseButton(managedCount, false);
   UpdateStatusLine(managedCount, false);
  }

//+------------------------------------------------------------------+
//| Unified Interactive Action Dispatchers (Instant 1-Click Response)|
//+------------------------------------------------------------------+
void TriggerActionCollapse()
  {
   g_IsCollapsed = !g_IsCollapsed;
   ObjectSetString(0, g_Prefix + "BtnCollapse", OBJPROP_TEXT, g_IsCollapsed ? "[+]" : "[-]");
   ClampPanelToChart();
   RepositionDashboard();
   UpdatePanelVisibility();
   ChartRedraw(0);
  }

void TriggerActionLotDown()
  {
   SyncLotFromEditBox();
   g_CurrentLot = NormalizeVolume(g_CurrentLot - g_VolStep);
   ObjectSetString(0, g_Prefix + "EdtLot", OBJPROP_TEXT, FormatLotString(g_CurrentLot));
   ChartRedraw(0);
  }

void TriggerActionLotUp()
  {
   SyncLotFromEditBox();
   g_CurrentLot = NormalizeVolume(g_CurrentLot + g_VolStep);
   ObjectSetString(0, g_Prefix + "EdtLot", OBJPROP_TEXT, FormatLotString(g_CurrentLot));
   ChartRedraw(0);
  }

void TriggerActionSell()
  {
   ExecuteMarketOrder(ORDER_TYPE_SELL);
   int cnt = CountEligiblePositions();
   RefreshCloseButton(cnt, true);
   ChartRedraw(0);
  }

void TriggerActionBuy()
  {
   ExecuteMarketOrder(ORDER_TYPE_BUY);
   int cnt = CountEligiblePositions();
   RefreshCloseButton(cnt, true);
   ChartRedraw(0);
  }

void TriggerActionClosePositions()
  {
   CloseEligiblePositions();
   int cnt = CountEligiblePositions();
   RefreshCloseButton(cnt, true);
   ChartRedraw(0);
  }

void TriggerActionTrailToggle()
  {
   g_TrailingEnabled = !g_TrailingEnabled;
   RefreshControlButtons();
   if(g_TrailingEnabled)
     {
      int sh = (InpSTTrailBar == ST_BAR_CLOSED) ? 1 : 0;
      SetStatusText(StringFormat("Trailing Stop: ACTIVATED (Sh.%d)", sh), clrLightGreen, 2500);
      ProcessOpenPositions();
     }
   else
     {
      SetStatusText("Trailing Stop: DISABLED", C'255,195,110', 2500);
     }
   ChartRedraw(0);
  }

void TriggerActionScopeToggle()
  {
   g_ManageScope = (g_ManageScope == SCOPE_CURRENT_SYMBOL) ? SCOPE_ALL_POSITIONS : SCOPE_CURRENT_SYMBOL;
   RefreshControlButtons();
   int cnt = CountEligiblePositions();
   RefreshCloseButton(cnt, true);

   string scopeMsg = (g_ManageScope == SCOPE_CURRENT_SYMBOL)
                     ? ("Scope: " + _Symbol + " Only")
                     : "Scope: Any Position (Account-Wide)";
   SetStatusText(scopeMsg, clrDeepSkyBlue, 2500);

   if(g_TrailingEnabled)
      ProcessOpenPositions();
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Handle Click by Screen Coordinates (Guaranteed 1st-Click Hit)    |
//+------------------------------------------------------------------+
bool HandleClickByCoordinates(int mouseX, int mouseY)
  {
   // 1. Collapse Button in Header
   if(PointInRect(mouseX, mouseY, g_PanelX + g_PanelWidth - 30, g_PanelY + 2, 26, 24))
     {
      TriggerActionCollapse();
      return true;
     }

   if(g_IsCollapsed)
      return false;

   int ocY = g_PanelY + 34;

   // 2. Lot Down Button
   if(PointInRect(mouseX, mouseY, g_PanelX + 100, ocY, 22, 24))
     {
      TriggerActionLotDown();
      return true;
     }

   // 3. Lot Up Button
   if(PointInRect(mouseX, mouseY, g_PanelX + 188, ocY, 22, 24))
     {
      TriggerActionLotUp();
      return true;
     }

   // 4. Entire SELL One-Click Area (Top SELL button + Lower Bid Price Box)
   if(PointInRect(mouseX, mouseY, g_PanelX + 10, ocY, 88, 25) ||
      PointInRect(mouseX, mouseY, g_PanelX + 10, ocY + 25, 143, 46))
     {
      TriggerActionSell();
      return true;
     }

   // 5. Entire BUY One-Click Area (Top BUY button + Lower Ask Price Box)
   if(PointInRect(mouseX, mouseY, g_PanelX + 212, ocY, 88, 25) ||
      PointInRect(mouseX, mouseY, g_PanelX + 157, ocY + 25, 143, 46))
     {
      TriggerActionBuy();
      return true;
     }

   // 6. Direct Close Position Button
   if(PointInRect(mouseX, mouseY, g_PanelX + 10, g_PanelY + 130, 290, 26))
     {
      TriggerActionClosePositions();
      return true;
     }

   // 7. Interactive Trailing Stop Toggle Button
   if(PointInRect(mouseX, mouseY, g_PanelX + 135, g_PanelY + 167, 165, 24))
     {
      TriggerActionTrailToggle();
      return true;
     }

   // 8. Interactive Manage Scope Toggle Button
   if(PointInRect(mouseX, mouseY, g_PanelX + 135, g_PanelY + 196, 165, 24))
     {
      TriggerActionScopeToggle();
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| ChartEvent function for interactive UI & bounded dragging        |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   //--- 1. Direct Chart Click Event (Guaranteed 1st-Click Hit Testing)
   if(id == CHARTEVENT_CLICK)
     {
      ulong now = GetTickCount64();
      if(now - g_LastClickMs < 150)
         return;

      int mouseX = (int)lparam;
      int mouseY = (int)dparam;
      if(HandleClickByCoordinates(mouseX, mouseY))
        {
         g_LastClickMs = now;
         return;
        }
     }

   //--- 2. Object Click Event (Direct Button Handler + Visual State Reset)
   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(StringFind(sparam, g_Prefix) == 0)
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);

      ulong now = GetTickCount64();
      if(now - g_LastClickMs < 150)
        {
         ChartRedraw(0);
         return;
        }

      if(sparam == g_Prefix + "BtnCollapse")
        {
         g_LastClickMs = now;
         TriggerActionCollapse();
         return;
        }
      if(sparam == g_Prefix + "BtnLotDown")
        {
         g_LastClickMs = now;
         TriggerActionLotDown();
         return;
        }
      if(sparam == g_Prefix + "BtnLotUp")
        {
         g_LastClickMs = now;
         TriggerActionLotUp();
         return;
        }
      if(sparam == g_Prefix + "BtnSellTop" || sparam == g_Prefix + "BtnSellPriceBg" ||
         sparam == g_Prefix + "lblBidMain" || sparam == g_Prefix + "lblBidPips" || sparam == g_Prefix + "lblBidPipe")
        {
         g_LastClickMs = now;
         TriggerActionSell();
         return;
        }
      if(sparam == g_Prefix + "BtnBuyTop" || sparam == g_Prefix + "BtnBuyPriceBg" ||
         sparam == g_Prefix + "lblAskMain" || sparam == g_Prefix + "lblAskPips" || sparam == g_Prefix + "lblAskPipe")
        {
         g_LastClickMs = now;
         TriggerActionBuy();
         return;
        }
      if(sparam == g_Prefix + "BtnClosePos")
        {
         g_LastClickMs = now;
         TriggerActionClosePositions();
         return;
        }
      if(sparam == g_Prefix + "BtnTrailToggle")
        {
         g_LastClickMs = now;
         TriggerActionTrailToggle();
         return;
        }
      if(sparam == g_Prefix + "BtnScopeToggle")
        {
         g_LastClickMs = now;
         TriggerActionScopeToggle();
         return;
        }
     }

   //--- 3. Handle Manual Lot Input Validation
   if(id == CHARTEVENT_OBJECT_ENDEDIT)
     {
      if(sparam == g_Prefix + "EdtLot")
        {
         SyncLotFromEditBox();
         ChartRedraw(0);
         return;
        }
     }

   //--- 4. Handle Chart Resize (Keep Panel Strictly Inside Chart Boundaries)
   if(id == CHARTEVENT_CHART_CHANGE)
     {
      int oldX = g_PanelX;
      int oldY = g_PanelY;
      ClampPanelToChart();
      if(g_PanelX != oldX || g_PanelY != oldY)
        {
         RepositionDashboard();
         ChartRedraw(0);
        }
     }

   //--- 5. Handle Panel Dragging with Strict Chart Boundary Enforcement
   if(id == CHARTEVENT_MOUSE_MOVE)
     {
      int  mouseX         = (int)lparam;
      int  mouseY         = (int)dparam;
      uint mouseState     = (uint)sparam;
      bool leftBtnPressed = ((mouseState & 1) == 1);

      if(leftBtnPressed && !g_IsDragging)
        {
         if(mouseX >= g_PanelX && mouseX <= (g_PanelX + g_PanelWidth - 32) &&
            mouseY >= g_PanelY && mouseY <= (g_PanelY + g_HeaderHeight))
           {
            g_IsDragging  = true;
            g_DragOffsetX = mouseX - g_PanelX;
            g_DragOffsetY = mouseY - g_PanelY;
            ChartSetInteger(0, CHART_MOUSE_SCROLL, false);
           }
        }

      if(g_IsDragging && leftBtnPressed)
        {
         g_PanelX = mouseX - g_DragOffsetX;
         g_PanelY = mouseY - g_DragOffsetY;
         ClampPanelToChart();
         RepositionDashboard();
         ChartRedraw(0);
        }

      if(!leftBtnPressed && g_IsDragging)
        {
         g_IsDragging = false;
         ChartSetInteger(0, CHART_MOUSE_SCROLL, true);
        }
     }
  }

//+------------------------------------------------------------------+
//| Clamp Panel Coordinates Strictly Inside Visible Chart Window     |
//+------------------------------------------------------------------+
void ClampPanelToChart()
  {
   int chartWidth  = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int chartHeight = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);

   if(chartWidth <= 0 || chartHeight <= 0)
      return;

   int currentHeight = g_IsCollapsed ? g_HeaderHeight : g_PanelHeight;
   int maxX          = MathMax(0, chartWidth - g_PanelWidth);
   int maxY          = MathMax(0, chartHeight - currentHeight);

   g_PanelX = MathMax(0, MathMin(g_PanelX, maxX));
   g_PanelY = MathMax(0, MathMin(g_PanelY, maxY));
  }

//+------------------------------------------------------------------+
//| Initialize & Normalize Broker Lot Constraints                    |
//+------------------------------------------------------------------+
void InitVolumeConstraints()
  {
   double vMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   g_VolMin  = (vMin  > 0.0) ? vMin  : 0.01;
   g_VolMax  = (vMax  > 0.0) ? vMax  : 100.0;
   g_VolStep = (vStep > 0.0) ? vStep : 0.01;

   g_CurrentLot = NormalizeVolume(InpDefaultLot);
  }

double NormalizeVolume(double rawLot)
  {
   if(rawLot < g_VolMin)
      rawLot = g_VolMin;
   if(rawLot > g_VolMax)
      rawLot = g_VolMax;

   double steps = MathRound((rawLot - g_VolMin) / g_VolStep);
   double norm  = g_VolMin + steps * g_VolStep;

   if(norm < g_VolMin) norm = g_VolMin;
   if(norm > g_VolMax) norm = g_VolMax;

   int volDigits = GetVolumeDigits(g_VolStep);
   return NormalizeDouble(norm, volDigits);
  }

int GetVolumeDigits(double step)
  {
   if(step >= 1.0)  return 0;
   if(step >= 0.1)  return 1;
   if(step >= 0.01) return 2;
   return 3;
  }

string FormatLotString(double lot)
  {
   return DoubleToString(lot, GetVolumeDigits(g_VolStep));
  }

void SyncLotFromEditBox()
  {
   string txt = ObjectGetString(0, g_Prefix + "EdtLot", OBJPROP_TEXT);
   double val = StringToDouble(txt);
   if(val <= 0.0)
      val = g_VolMin;

   g_CurrentLot = NormalizeVolume(val);
   ObjectSetString(0, g_Prefix + "EdtLot", OBJPROP_TEXT, FormatLotString(g_CurrentLot));
  }

//+------------------------------------------------------------------+
//| Configure Supported Broker Filling Mode for CTrade               |
//+------------------------------------------------------------------+
void ConfigureBestFillingMode(CTrade &tradeObj, const string symbol)
  {
   uint filling = (uint)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      tradeObj.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      tradeObj.SetTypeFilling(ORDER_FILLING_IOC);
   else
      tradeObj.SetTypeFilling(ORDER_FILLING_RETURN);
  }

//+------------------------------------------------------------------+
//| Execute One-Click Market Buy or Sell Order                       |
//+------------------------------------------------------------------+
void ExecuteMarketOrder(ENUM_ORDER_TYPE orderType)
  {
   SyncLotFromEditBox();

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      SetStatusText("Error: Enable Algo Trading in MT5!", clrOrangeRed, 3500);
      return;
     }

   ConfigureBestFillingMode(g_OrderTrade, _Symbol);
   g_OrderTrade.SetExpertMagicNumber(InpMagicFilter);

   bool result = false;
   if(orderType == ORDER_TYPE_BUY)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      result = g_OrderTrade.Buy(g_CurrentLot, _Symbol, ask, 0.0, 0.0, "ST Assistant Buy");
     }
   else if(orderType == ORDER_TYPE_SELL)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      result = g_OrderTrade.Sell(g_CurrentLot, _Symbol, bid, 0.0, 0.0, "ST Assistant Sell");
     }

   if(result)
     {
      string sideStr = (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL";
      SetStatusText(StringFormat("%s %s Executed (#%I64u)", sideStr, FormatLotString(g_CurrentLot), g_OrderTrade.ResultOrder()), clrLightGreen, 3000);

      if(g_TrailingEnabled && g_ActiveManager != NULL)
         ProcessOpenPositions();
     }
   else
     {
      SetStatusText(StringFormat("Order Failed (Code %d)", g_OrderTrade.ResultRetcode()), clrOrangeRed, 3500);
     }
  }

//+------------------------------------------------------------------+
//| Close Eligible Open Positions Directly (1-Click Action)          |
//+------------------------------------------------------------------+
void CloseEligiblePositions()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      SetStatusText("Error: Enable Algo Trading in MT5!", clrOrangeRed, 3500);
      return;
     }

   int closedCount = 0;
   int failedCount = 0;
   uint lastErr    = 0;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!IsPositionEligible(ticket))
         continue;

      string posSymbol = PositionGetString(POSITION_SYMBOL);
      ConfigureBestFillingMode(g_OrderTrade, posSymbol);

      if(g_OrderTrade.PositionClose(ticket, InpSlippagePoints))
         closedCount++;
      else
        {
         failedCount++;
         lastErr = g_OrderTrade.ResultRetcode();
        }
     }

   if(closedCount > 0 && failedCount == 0)
     {
      SetStatusText(StringFormat("Closed %d Position(s) Successfully", closedCount), clrLightGreen, 3000);
     }
   else if(closedCount > 0 && failedCount > 0)
     {
      SetStatusText(StringFormat("Closed %d | Failed %d (Err %d)", closedCount, failedCount, lastErr), clrOrange, 3500);
     }
   else if(failedCount > 0)
     {
      SetStatusText(StringFormat("Close Failed (Code %d)", lastErr), clrOrangeRed, 3500);
     }
   else
     {
      string scopeHint = (g_ManageScope == SCOPE_CURRENT_SYMBOL) ? ("on " + _Symbol) : "on Account";
      SetStatusText("No Open Positions " + scopeHint, C'255,195,110', 2500);
     }
  }

//+------------------------------------------------------------------+
//| Position Adoption & Management Loop                              |
//+------------------------------------------------------------------+
bool IsPositionEligible(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return false;

   if(InpMagicFilter > 0)
     {
      ulong posMagic = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(posMagic != InpMagicFilter)
         return false;
     }

   if(g_ManageScope == SCOPE_CURRENT_SYMBOL)
     {
      string posSymbol = PositionGetString(POSITION_SYMBOL);
      if(posSymbol != _Symbol)
         return false;
     }

   return true;
  }

int CountEligiblePositions()
  {
   int count = 0;
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && IsPositionEligible(ticket))
         count++;
     }
   return count;
  }

void ProcessOpenPositions()
  {
   if(g_ActiveManager == NULL)
      return;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!IsPositionEligible(ticket))
         continue;

      if(g_ActiveManager.ManagePosition(ticket))
        {
         string msg = g_ActiveManager.GetLastActionMessage();
         if(msg != "")
            SetStatusText(msg, clrLightGreen, 2500);
        }
     }
  }

//+------------------------------------------------------------------+
//| Draw SuperTrend Lines on Chart (No Canvas, Pure Trend Segments)  |
//| Direction/Color flips ONLY when closed candle (Shift 1) confirms |
//+------------------------------------------------------------------+
void ClearSuperTrendLines()
  {
   ObjectsDeleteAll(0, g_Prefix + "ST_Seg_");
   g_LastDrawnBars = 0;
  }

void UpdateSuperTrendChartLines(bool forceFullRedraw)
  {
   if(!InpShowSTLines)
     {
      if(g_LastDrawnBars > 0)
        {
         ClearSuperTrendLines();
         ChartRedraw(0);
        }
      return;
     }

   int availableBars = iBars(_Symbol, InpSTTimeframe);
   if(availableBars <= InpSTAtrPeriod + 2)
      return;

   int drawBars = MathMin(InpSTDrawBars, availableBars - InpSTAtrPeriod - 2);
   if(drawBars < 2)
      return;

   datetime currentSTBarTime = iTime(_Symbol, InpSTTimeframe, 0);
   bool isNewBar = (currentSTBarTime != g_LastSTBarTime);

   // Recompute closed candles (Shift 1 .. drawBars) ONLY on init or when a new bar closes
   if(forceFullRedraw || isNewBar || ArraySize(g_CacheSTVal) < drawBars + 1)
     {
      ArrayResize(g_CacheSTVal, drawBars + 1);
      ArrayResize(g_CacheSTDir, drawBars + 1);
      ArrayResize(g_CacheSTTime, drawBars + 1);

      for(int s = drawBars; s >= 1; s--)
        {
         int dir = 0;
         double val = g_ChartSTEngine.GetSuperTrend(s, dir);
         g_CacheSTVal[s]  = val;
         g_CacheSTDir[s]  = dir;
         g_CacheSTTime[s] = iTime(_Symbol, InpSTTimeframe, s);
        }

      for(int s = drawBars - 1; s >= 1; s--)
        {
         DrawSuperTrendSegment(s, g_CacheSTTime[s + 1], g_CacheSTVal[s + 1], g_CacheSTDir[s + 1],
                                  g_CacheSTTime[s],     g_CacheSTVal[s],     g_CacheSTDir[s]);
        }

      if(g_LastDrawnBars > drawBars)
        {
         for(int k = drawBars; k < g_LastDrawnBars; k++)
            ObjectDelete(0, g_Prefix + "ST_Seg_" + IntegerToString(k));
        }

      g_LastSTBarTime = currentSTBarTime;
      g_LastDrawnBars = drawBars;
     }

   // Live candle (Shift 0) keeps the confirmed direction/color of closed candle Shift 1
   // so color NEVER flips prematurely before candle close!
   int confirmedDir = g_CacheSTDir[1];
   double liveBandVal = 0.0;
   if(confirmedDir == 1)
      liveBandVal = g_ChartSTEngine.GetStopLossPrice(0, POSITION_TYPE_BUY);
   else if(confirmedDir == -1)
      liveBandVal = g_ChartSTEngine.GetStopLossPrice(0, POSITION_TYPE_SELL);

   g_CacheSTVal[0]  = liveBandVal;
   g_CacheSTDir[0]  = confirmedDir;
   g_CacheSTTime[0] = currentSTBarTime;

   DrawSuperTrendSegment(0, g_CacheSTTime[1], g_CacheSTVal[1], confirmedDir,
                            g_CacheSTTime[0], g_CacheSTVal[0], confirmedDir);
  }

void DrawSuperTrendSegment(int segIndex, datetime t1, double p1, int dir1, datetime t2, double p2, int dir2)
  {
   string objName = g_Prefix + "ST_Seg_" + IntegerToString(segIndex);

   if(p2 <= 0.0 || dir2 == 0 || t2 == 0)
     {
      ObjectDelete(0, objName);
      return;
     }

   // Green when closed candle is above SuperTrend (dir == 1), Red when closed candle is below (dir == -1)
   color segColor = (dir2 == 1) ? InpSTUpColor : InpSTDownColor;

   datetime startTime  = t1;
   double   startPrice = p1;
   datetime endTime    = t2;
   double   endPrice   = p2;

   // On a confirmed trend flip bar (dir1 != dir2), start cleanly at the new level across the bar's span
   if(dir1 != dir2 || p1 <= 0.0 || t1 == 0)
     {
      startTime  = t2;
      startPrice = p2;
      endTime    = t2 + (datetime)PeriodSeconds(InpSTTimeframe);
      endPrice   = p2;
     }

   if(ObjectFind(0, objName) < 0)
     {
      ObjectCreate(0, objName, OBJ_TREND, 0, startTime, startPrice, endTime, endPrice);
      ObjectSetInteger(0, objName, OBJPROP_RAY_RIGHT,  false);
      ObjectSetInteger(0, objName, OBJPROP_RAY_LEFT,   false);
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, objName, OBJPROP_HIDDEN,     true);
      ObjectSetInteger(0, objName, OBJPROP_BACK,       true);
      ObjectSetInteger(0, objName, OBJPROP_ZORDER,     0);
     }
   else
     {
      if((datetime)ObjectGetInteger(0, objName, OBJPROP_TIME, 0) != startTime)
         ObjectSetInteger(0, objName, OBJPROP_TIME, 0, startTime);
      if(ObjectGetDouble(0, objName, OBJPROP_PRICE, 0) != startPrice)
         ObjectSetDouble(0, objName, OBJPROP_PRICE, 0, startPrice);
      if((datetime)ObjectGetInteger(0, objName, OBJPROP_TIME, 1) != endTime)
         ObjectSetInteger(0, objName, OBJPROP_TIME, 1, endTime);
      if(ObjectGetDouble(0, objName, OBJPROP_PRICE, 1) != endPrice)
         ObjectSetDouble(0, objName, OBJPROP_PRICE, 1, endPrice);
     }

   if((color)ObjectGetInteger(0, objName, OBJPROP_COLOR) != segColor)
      ObjectSetInteger(0, objName, OBJPROP_COLOR, segColor);

   ObjectSetInteger(0, objName, OBJPROP_WIDTH, MathMax(1, InpSTLineWidth));
   ObjectSetInteger(0, objName, OBJPROP_STYLE, STYLE_SOLID);
  }

//+------------------------------------------------------------------+
//| Format Live Price into MT5 One-Click Parts (Main / Pips / Pipe)  |
//+------------------------------------------------------------------+
void SplitPriceForMT5Display(double price, int digits, string &outMain, string &outPips, string &outPipe)
  {
   string str = DoubleToString(price, digits);
   int len = StringLen(str);

   if(digits >= 3 && len >= 4)
     {
      outPipe = StringSubstr(str, len - 1, 1);
      outPips = StringSubstr(str, len - 3, 2);
      outMain = StringSubstr(str, 0, len - 3);
     }
   else if(digits == 2 && len >= 3)
     {
      outPipe = "";
      outPips = StringSubstr(str, len - 2, 2);
      outMain = StringSubstr(str, 0, len - 2);
     }
   else if(digits == 1 && len >= 4)
     {
      outPipe = StringSubstr(str, len - 1, 1);
      outPips = StringSubstr(str, len - 4, 2);
      outMain = StringSubstr(str, 0, len - 4);
     }
   else if(len >= 2)
     {
      outPipe = "";
      outPips = StringSubstr(str, len - 2, 2);
      outMain = StringSubstr(str, 0, len - 2);
     }
   else
     {
      outMain = str;
      outPips = "";
      outPipe = "";
     }
  }

void UpdateLiveQuotes()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   string bidMain, bidPips, bidPipe;
   string askMain, askPips, askPipe;

   SplitPriceForMT5Display(bid, _Digits, bidMain, bidPips, bidPipe);
   SplitPriceForMT5Display(ask, _Digits, askMain, askPips, askPipe);

   if(bidMain != g_PrevBidMain) { ObjectSetString(0, g_Prefix + "lblBidMain", OBJPROP_TEXT, bidMain); g_PrevBidMain = bidMain; }
   if(bidPips != g_PrevBidPips) { ObjectSetString(0, g_Prefix + "lblBidPips", OBJPROP_TEXT, bidPips); g_PrevBidPips = bidPips; }
   if(bidPipe != g_PrevBidPipe) { ObjectSetString(0, g_Prefix + "lblBidPipe", OBJPROP_TEXT, bidPipe); g_PrevBidPipe = bidPipe; }

   if(askMain != g_PrevAskMain) { ObjectSetString(0, g_Prefix + "lblAskMain", OBJPROP_TEXT, askMain); g_PrevAskMain = askMain; }
   if(askPips != g_PrevAskPips) { ObjectSetString(0, g_Prefix + "lblAskPips", OBJPROP_TEXT, askPips); g_PrevAskPips = askPips; }
   if(askPipe != g_PrevAskPipe) { ObjectSetString(0, g_Prefix + "lblAskPipe", OBJPROP_TEXT, askPipe); g_PrevAskPipe = askPipe; }
  }

//+------------------------------------------------------------------+
//| Dashboard Creation & Layout Management                           |
//+------------------------------------------------------------------+
void RegisterBodyObject(const string shortName)
  {
   int sz = ArraySize(g_BodyObjects);
   ArrayResize(g_BodyObjects, sz + 1);
   g_BodyObjects[sz] = g_Prefix + shortName;
  }

void CreateDashboard()
  {
   ArrayResize(g_BodyObjects, 0);

   // Main Frame & Header (Z-Order 0)
   CreateRectLabel("BgFrame",     g_PanelX, g_PanelY, g_PanelWidth, g_PanelHeight, C'26,30,38', C'65,75,92', 1);
   CreateRectLabel("HeaderBg",    g_PanelX, g_PanelY, g_PanelWidth, g_HeaderHeight, C'31,78,121', C'31,78,121', 0);
   CreateLabel("HeaderTitle",     "ST POSITION ASSISTANT v3.0", g_PanelX + 10, g_PanelY + 6, clrWhite, 9, true);
   CreateButton("BtnCollapse",    g_IsCollapsed ? "[+]" : "[-]", g_PanelX + g_PanelWidth - 28, g_PanelY + 4, 22, 20, C'22,58,92', clrWhite, 8, true);

   // --- MT5-Style One-Click Trading Block ---
   int ocY = g_PanelY + 34;

   // Top Row: SELL Button | [-] [Lot Edit] [+] | BUY Button
   CreateButton("BtnSellTop",     "SELL", g_PanelX + 10,  ocY, 88, 24, C'200,45,55', clrWhite, 9, true);
   CreateButton("BtnLotDown",     "▼",    g_PanelX + 100, ocY, 22, 24, C'235,238,242', C'30,30,30', 8, true);
   CreateEditBox("EdtLot",        FormatLotString(g_CurrentLot), g_PanelX + 123, ocY, 64, 24, clrWhite, C'20,20,20', C'180,185,195', 9);
   CreateButton("BtnLotUp",       "▲",    g_PanelX + 188, ocY, 22, 24, C'235,238,242', C'30,30,30', 8, true);
   CreateButton("BtnBuyTop",      "BUY",  g_PanelX + 212, ocY, 88, 24, C'28,92,214', clrWhite, 9, true);

   // Bottom Row: Clickable Live Bid & Ask Price Boxes
   CreateButton("BtnSellPriceBg", "", g_PanelX + 10,  ocY + 25, 143, 46, C'200,45,55', clrWhite, 8, false);
   CreateButton("BtnBuyPriceBg",  "", g_PanelX + 157, ocY + 25, 143, 46, C'28,92,214', clrWhite, 8, false);

   // Live Bid Price Labels (Left Box)
   CreateLabel("lblBidMain", "0.00", g_PanelX + 66,  ocY + 43, clrWhite, 10, false);
   ObjectSetInteger(0, g_Prefix + "lblBidMain", OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
   CreateLabel("lblBidPips", "00",   g_PanelX + 68,  ocY + 30, clrWhite, 18, true);
   CreateLabel("lblBidPipe", "0",    g_PanelX + 114, ocY + 29, clrWhite, 9,  true);

   // Live Ask Price Labels (Right Box)
   CreateLabel("lblAskMain", "0.00", g_PanelX + 213, ocY + 43, clrWhite, 10, false);
   ObjectSetInteger(0, g_Prefix + "lblAskMain", OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
   CreateLabel("lblAskPips", "00",   g_PanelX + 215, ocY + 30, clrWhite, 18, true);
   CreateLabel("lblAskPipe", "0",    g_PanelX + 261, ocY + 29, clrWhite, 9,  true);

   // Broker Lot Limits Caption
   string lotInfo = StringFormat("Broker Vol  |  Min: %s   Step: %s   Max: %s",
                                 FormatLotString(g_VolMin), FormatLotString(g_VolStep), FormatLotString(g_VolMax));
   CreateLabel("lblLotLimits", lotInfo, g_PanelX + 12, ocY + 74, C'165,175,190', 7, false);

   // Divider Line 1
   CreateRectLabel("SepLine1", g_PanelX + 10, g_PanelY + 123, 290, 1, C'55,63,78', C'55,63,78', 0);

   // --- Direct One-Click Close Position Button ---
   CreateButton("BtnClosePos", "CLOSE POSITION (0)", g_PanelX + 10, g_PanelY + 130, 290, 26, C'95,52,58', clrWhite, 9, true);

   // Divider Line 2
   CreateRectLabel("SepLine2", g_PanelX + 10, g_PanelY + 161, 290, 1, C'55,63,78', C'55,63,78', 0);

   // --- Interactive Position Management Controls ---
   CreateLabel("lblTrailTitle", "Trailing Stop:", g_PanelX + 12, g_PanelY + 171, C'220,225,232', 8, true);
   CreateButton("BtnTrailToggle", "", g_PanelX + 135, g_PanelY + 167, 165, 24, C'75,82,96', clrWhite, 8, true);

   CreateLabel("lblScopeTitle", "Manage Scope:", g_PanelX + 12, g_PanelY + 200, C'220,225,232', 8, true);
   CreateButton("BtnScopeToggle", "", g_PanelX + 135, g_PanelY + 196, 165, 24, C'45,95,145', clrWhite, 8, true);

   // Informational Engine Badge (Displays active trailing shift: Sh.0 or Sh.1)
   CreateLabel("lblModeTitle",  "Trail Engine:", g_PanelX + 12, g_PanelY + 229, C'220,225,232', 8, true);
   CreateRectLabel("BadgeModeBg", g_PanelX + 135, g_PanelY + 225, 165, 22, C'36,42,54', C'60,70,88', 1);
   CreateLabel("lblModeValue",  "SuperTrend (Sh.0)", g_PanelX + 148, g_PanelY + 229, C'160,195,230', 8, false);

   // Status Line & Copyright Footer
   CreateLabel("lblStatus", "Ready | Managed Positions: 0", g_PanelX + 12, g_PanelY + 255, C'110,210,175', 7, false);
   CreateLabel("lblFooter", "Copyright 2026, Eng.Alhassan Ali Mubarak Bahbah", g_PanelX + 12, g_PanelY + 273, C'135,145,160', 7, false);

   // Register all body elements for clean collapse/expand toggling
   RegisterBodyObject("BtnSellTop");
   RegisterBodyObject("BtnLotDown");
   RegisterBodyObject("EdtLot");
   RegisterBodyObject("BtnLotUp");
   RegisterBodyObject("BtnBuyTop");
   RegisterBodyObject("BtnSellPriceBg");
   RegisterBodyObject("BtnBuyPriceBg");
   RegisterBodyObject("lblBidMain");
   RegisterBodyObject("lblBidPips");
   RegisterBodyObject("lblBidPipe");
   RegisterBodyObject("lblAskMain");
   RegisterBodyObject("lblAskPips");
   RegisterBodyObject("lblAskPipe");
   RegisterBodyObject("lblLotLimits");
   RegisterBodyObject("SepLine1");
   RegisterBodyObject("BtnClosePos");
   RegisterBodyObject("SepLine2");
   RegisterBodyObject("lblTrailTitle");
   RegisterBodyObject("BtnTrailToggle");
   RegisterBodyObject("lblScopeTitle");
   RegisterBodyObject("BtnScopeToggle");
   RegisterBodyObject("lblModeTitle");
   RegisterBodyObject("BadgeModeBg");
   RegisterBodyObject("lblModeValue");
   RegisterBodyObject("lblStatus");
   RegisterBodyObject("lblFooter");

   RefreshControlButtons();
   UpdatePanelVisibility();
  }

void RefreshCloseButton(int eligibleCount, bool forceUpdate)
  {
   if(!forceUpdate && eligibleCount == g_PrevCloseCount && g_ManageScope == g_PrevCloseScope)
      return;

   g_PrevCloseCount = eligibleCount;
   g_PrevCloseScope = g_ManageScope;

   string btnText = "";
   if(g_ManageScope == SCOPE_ALL_POSITIONS)
      btnText = StringFormat("CLOSE ALL POSITIONS (%d)", eligibleCount);
   else
      btnText = StringFormat("CLOSE %s POSITION (%d)", _Symbol, eligibleCount);

   color bgClr  = (eligibleCount > 0) ? C'192,42,54' : C'78,52,58';
   color txtClr = (eligibleCount > 0) ? clrWhite     : C'195,180,185';

   ObjectSetString(0,  g_Prefix + "BtnClosePos", OBJPROP_TEXT,         btnText);
   ObjectSetInteger(0, g_Prefix + "BtnClosePos", OBJPROP_BGCOLOR,      bgClr);
   ObjectSetInteger(0, g_Prefix + "BtnClosePos", OBJPROP_BORDER_COLOR, bgClr);
   ObjectSetInteger(0, g_Prefix + "BtnClosePos", OBJPROP_COLOR,        txtClr);
  }

void RefreshControlButtons()
  {
   if(g_TrailingEnabled)
     {
      ObjectSetString(0,  g_Prefix + "BtnTrailToggle", OBJPROP_TEXT,    "ACTIVE  [ ON ]");
      ObjectSetInteger(0, g_Prefix + "BtnTrailToggle", OBJPROP_BGCOLOR, C'24,154,82');
      ObjectSetInteger(0, g_Prefix + "BtnTrailToggle", OBJPROP_COLOR,   clrWhite);
     }
   else
     {
      ObjectSetString(0,  g_Prefix + "BtnTrailToggle", OBJPROP_TEXT,    "DISABLED  [ OFF ]");
      ObjectSetInteger(0, g_Prefix + "BtnTrailToggle", OBJPROP_BGCOLOR, C'75,82,96');
      ObjectSetInteger(0, g_Prefix + "BtnTrailToggle", OBJPROP_COLOR,   C'210,215,222');
     }

   if(g_ManageScope == SCOPE_CURRENT_SYMBOL)
     {
      ObjectSetString(0,  g_Prefix + "BtnScopeToggle", OBJPROP_TEXT,    "Current Chart Only");
      ObjectSetInteger(0, g_Prefix + "BtnScopeToggle", OBJPROP_BGCOLOR, C'45,95,145');
     }
   else
     {
      ObjectSetString(0,  g_Prefix + "BtnScopeToggle", OBJPROP_TEXT,    "Any Position (Account)");
      ObjectSetInteger(0, g_Prefix + "BtnScopeToggle", OBJPROP_BGCOLOR, C'180,115,25');
     }

   string modeName = (g_ActiveManager != NULL) ? g_ActiveManager.GetStrategyName() : "SuperTrend (Sh.0)";
   ObjectSetString(0, g_Prefix + "lblModeValue", OBJPROP_TEXT, modeName);
  }

void SetStatusText(const string text, color clr, ulong holdMs = 0)
  {
   if(holdMs > 0)
      g_StatusHoldUntil = GetTickCount64() + holdMs;

   if(text != g_PrevStatusText)
     {
      ObjectSetString(0, g_Prefix + "lblStatus", OBJPROP_TEXT, text);
      g_PrevStatusText = text;
     }
   if(clr != g_PrevStatusColor)
     {
      ObjectSetInteger(0, g_Prefix + "lblStatus", OBJPROP_COLOR, clr);
      g_PrevStatusColor = clr;
     }
  }

void UpdateStatusLine(int managedCount, bool forceUpdate)
  {
   if(!forceUpdate && GetTickCount64() < g_StatusHoldUntil)
      return;

   string stateStr = g_TrailingEnabled ? "Trail: ON" : "Trail: OFF";
   string scopeStr = (g_ManageScope == SCOPE_CURRENT_SYMBOL) ? _Symbol : "All Symbols";
   int    confDir  = (ArraySize(g_CacheSTDir) > 1) ? g_CacheSTDir[1] : 0;
   string dirStr   = (confDir == 1) ? "BULL" : ((confDir == -1) ? "BEAR" : "-");
   string stValStr = (ArraySize(g_CacheSTVal) > 0 && g_CacheSTVal[0] > 0.0) ? DoubleToString(g_CacheSTVal[0], _Digits) : "-";

   string line = StringFormat("%s | %s (%d) | %s %s", stateStr, scopeStr, managedCount, dirStr, stValStr);
   color  clr  = g_TrailingEnabled ? C'110,210,175' : C'175,185,200';
   SetStatusText(line, clr, 0);
  }

void UpdatePanelVisibility()
  {
   long tfVisibility = g_IsCollapsed ? OBJ_NO_PERIODS : OBJ_ALL_PERIODS;
   int total = ArraySize(g_BodyObjects);
   for(int i = 0; i < total; i++)
     {
      ObjectSetInteger(0, g_BodyObjects[i], OBJPROP_TIMEFRAMES, tfVisibility);
     }

   int newHeight = g_IsCollapsed ? g_HeaderHeight : g_PanelHeight;
   ObjectSetInteger(0, g_Prefix + "BgFrame", OBJPROP_YSIZE, newHeight);
  }

void RepositionDashboard()
  {
   ObjectSetInteger(0, g_Prefix + "BgFrame",        OBJPROP_XDISTANCE, g_PanelX);
   ObjectSetInteger(0, g_Prefix + "BgFrame",        OBJPROP_YDISTANCE, g_PanelY);

   ObjectSetInteger(0, g_Prefix + "HeaderBg",       OBJPROP_XDISTANCE, g_PanelX);
   ObjectSetInteger(0, g_Prefix + "HeaderBg",       OBJPROP_YDISTANCE, g_PanelY);

   ObjectSetInteger(0, g_Prefix + "HeaderTitle",    OBJPROP_XDISTANCE, g_PanelX + 10);
   ObjectSetInteger(0, g_Prefix + "HeaderTitle",    OBJPROP_YDISTANCE, g_PanelY + 6);

   ObjectSetInteger(0, g_Prefix + "BtnCollapse",    OBJPROP_XDISTANCE, g_PanelX + g_PanelWidth - 28);
   ObjectSetInteger(0, g_Prefix + "BtnCollapse",    OBJPROP_YDISTANCE, g_PanelY + 4);

   int ocY = g_PanelY + 34;

   ObjectSetInteger(0, g_Prefix + "BtnSellTop",     OBJPROP_XDISTANCE, g_PanelX + 10);
   ObjectSetInteger(0, g_Prefix + "BtnSellTop",     OBJPROP_YDISTANCE, ocY);

   ObjectSetInteger(0, g_Prefix + "BtnLotDown",     OBJPROP_XDISTANCE, g_PanelX + 100);
   ObjectSetInteger(0, g_Prefix + "BtnLotDown",     OBJPROP_YDISTANCE, ocY);

   ObjectSetInteger(0, g_Prefix + "EdtLot",         OBJPROP_XDISTANCE, g_PanelX + 123);
   ObjectSetInteger(0, g_Prefix + "EdtLot",         OBJPROP_YDISTANCE, ocY);

   ObjectSetInteger(0, g_Prefix + "BtnLotUp",       OBJPROP_XDISTANCE, g_PanelX + 188);
   ObjectSetInteger(0, g_Prefix + "BtnLotUp",       OBJPROP_YDISTANCE, ocY);

   ObjectSetInteger(0, g_Prefix + "BtnBuyTop",      OBJPROP_XDISTANCE, g_PanelX + 212);
   ObjectSetInteger(0, g_Prefix + "BtnBuyTop",      OBJPROP_YDISTANCE, ocY);

   ObjectSetInteger(0, g_Prefix + "BtnSellPriceBg", OBJPROP_XDISTANCE, g_PanelX + 10);
   ObjectSetInteger(0, g_Prefix + "BtnSellPriceBg", OBJPROP_YDISTANCE, ocY + 25);

   ObjectSetInteger(0, g_Prefix + "BtnBuyPriceBg",  OBJPROP_XDISTANCE, g_PanelX + 157);
   ObjectSetInteger(0, g_Prefix + "BtnBuyPriceBg",  OBJPROP_YDISTANCE, ocY + 25);

   ObjectSetInteger(0, g_Prefix + "lblBidMain",     OBJPROP_XDISTANCE, g_PanelX + 66);
   ObjectSetInteger(0, g_Prefix + "lblBidMain",     OBJPROP_YDISTANCE, ocY + 43);
   ObjectSetInteger(0, g_Prefix + "lblBidPips",     OBJPROP_XDISTANCE, g_PanelX + 68);
   ObjectSetInteger(0, g_Prefix + "lblBidPips",     OBJPROP_YDISTANCE, ocY + 30);
   ObjectSetInteger(0, g_Prefix + "lblBidPipe",     OBJPROP_XDISTANCE, g_PanelX + 114);
   ObjectSetInteger(0, g_Prefix + "lblBidPipe",     OBJPROP_YDISTANCE, ocY + 29);

   ObjectSetInteger(0, g_Prefix + "lblAskMain",     OBJPROP_XDISTANCE, g_PanelX + 213);
   ObjectSetInteger(0, g_Prefix + "lblAskMain",     OBJPROP_YDISTANCE, ocY + 43);
   ObjectSetInteger(0, g_Prefix + "lblAskPips",     OBJPROP_XDISTANCE, g_PanelX + 215);
   ObjectSetInteger(0, g_Prefix + "lblAskPips",     OBJPROP_YDISTANCE, ocY + 30);
   ObjectSetInteger(0, g_Prefix + "lblAskPipe",     OBJPROP_XDISTANCE, g_PanelX + 261);
   ObjectSetInteger(0, g_Prefix + "lblAskPipe",     OBJPROP_YDISTANCE, ocY + 29);

   ObjectSetInteger(0, g_Prefix + "lblLotLimits",   OBJPROP_XDISTANCE, g_PanelX + 12);
   ObjectSetInteger(0, g_Prefix + "lblLotLimits",   OBJPROP_YDISTANCE, ocY + 74);

   ObjectSetInteger(0, g_Prefix + "SepLine1",       OBJPROP_XDISTANCE, g_PanelX + 10);
   ObjectSetInteger(0, g_Prefix + "SepLine1",       OBJPROP_YDISTANCE, g_PanelY + 123);

   ObjectSetInteger(0, g_Prefix + "BtnClosePos",    OBJPROP_XDISTANCE, g_PanelX + 10);
   ObjectSetInteger(0, g_Prefix + "BtnClosePos",    OBJPROP_YDISTANCE, g_PanelY + 130);

   ObjectSetInteger(0, g_Prefix + "SepLine2",       OBJPROP_XDISTANCE, g_PanelX + 10);
   ObjectSetInteger(0, g_Prefix + "SepLine2",       OBJPROP_YDISTANCE, g_PanelY + 161);

   ObjectSetInteger(0, g_Prefix + "lblTrailTitle",  OBJPROP_XDISTANCE, g_PanelX + 12);
   ObjectSetInteger(0, g_Prefix + "lblTrailTitle",  OBJPROP_YDISTANCE, g_PanelY + 171);
   ObjectSetInteger(0, g_Prefix + "BtnTrailToggle", OBJPROP_XDISTANCE, g_PanelX + 135);
   ObjectSetInteger(0, g_Prefix + "BtnTrailToggle", OBJPROP_YDISTANCE, g_PanelY + 167);

   ObjectSetInteger(0, g_Prefix + "lblScopeTitle",  OBJPROP_XDISTANCE, g_PanelX + 12);
   ObjectSetInteger(0, g_Prefix + "lblScopeTitle",  OBJPROP_YDISTANCE, g_PanelY + 200);
   ObjectSetInteger(0, g_Prefix + "BtnScopeToggle", OBJPROP_XDISTANCE, g_PanelX + 135);
   ObjectSetInteger(0, g_Prefix + "BtnScopeToggle", OBJPROP_YDISTANCE, g_PanelY + 196);

   ObjectSetInteger(0, g_Prefix + "lblModeTitle",   OBJPROP_XDISTANCE, g_PanelX + 12);
   ObjectSetInteger(0, g_Prefix + "lblModeTitle",   OBJPROP_YDISTANCE, g_PanelY + 229);
   ObjectSetInteger(0, g_Prefix + "BadgeModeBg",    OBJPROP_XDISTANCE, g_PanelX + 135);
   ObjectSetInteger(0, g_Prefix + "BadgeModeBg",    OBJPROP_YDISTANCE, g_PanelY + 225);
   ObjectSetInteger(0, g_Prefix + "lblModeValue",   OBJPROP_XDISTANCE, g_PanelX + 148);
   ObjectSetInteger(0, g_Prefix + "lblModeValue",   OBJPROP_YDISTANCE, g_PanelY + 229);

   ObjectSetInteger(0, g_Prefix + "lblStatus",      OBJPROP_XDISTANCE, g_PanelX + 12);
   ObjectSetInteger(0, g_Prefix + "lblStatus",      OBJPROP_YDISTANCE, g_PanelY + 255);

   ObjectSetInteger(0, g_Prefix + "lblFooter",      OBJPROP_XDISTANCE, g_PanelX + 12);
   ObjectSetInteger(0, g_Prefix + "lblFooter",      OBJPROP_YDISTANCE, g_PanelY + 273);
  }

//+------------------------------------------------------------------+
//| Low-Level Chart UI Object Helpers (With Explicit Z-Order)        |
//+------------------------------------------------------------------+
void CreateRectLabel(const string name, int x, int y, int w, int h, color bg, color border, int borderWidth)
  {
   string objName = g_Prefix + name;
   ObjectDelete(0, objName);
   ObjectCreate(0, objName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE,    x);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE,    y);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE,        w);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE,        h);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR,      bg);
   ObjectSetInteger(0, objName, OBJPROP_BORDER_COLOR, border);
   ObjectSetInteger(0, objName, OBJPROP_BORDER_TYPE,  BORDER_FLAT);
   ObjectSetInteger(0, objName, OBJPROP_WIDTH,        borderWidth);
   ObjectSetInteger(0, objName, OBJPROP_CORNER,       CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE,   false);
   ObjectSetInteger(0, objName, OBJPROP_BACK,         false);
   ObjectSetInteger(0, objName, OBJPROP_ZORDER,       0);
  }

void CreateLabel(const string name, const string text, int x, int y, color clr, int fontSize, bool isBold)
  {
   string objName = g_Prefix + name;
   ObjectDelete(0, objName);
   ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE,  y);
   ObjectSetString(0,  objName, OBJPROP_TEXT,       text);
   ObjectSetString(0,  objName, OBJPROP_FONT,       isBold ? "Segoe UI Bold" : "Segoe UI");
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE,   fontSize);
   ObjectSetInteger(0, objName, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, objName, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, objName, OBJPROP_BACK,       false);
   ObjectSetInteger(0, objName, OBJPROP_ZORDER,     1);
  }

void CreateButton(const string name, const string text, int x, int y, int w, int h, color bg, color clr, int fontSize, bool isBold)
  {
   string objName = g_Prefix + name;
   ObjectDelete(0, objName);
   ObjectCreate(0, objName, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE,    x);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE,    y);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE,        w);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE,        h);
   ObjectSetString(0,  objName, OBJPROP_TEXT,         text);
   ObjectSetString(0,  objName, OBJPROP_FONT,         isBold ? "Segoe UI Bold" : "Segoe UI");
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE,     fontSize);
   ObjectSetInteger(0, objName, OBJPROP_COLOR,        clr);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR,      bg);
   ObjectSetInteger(0, objName, OBJPROP_BORDER_COLOR, bg);
   ObjectSetInteger(0, objName, OBJPROP_CORNER,       CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE,   false);
   ObjectSetInteger(0, objName, OBJPROP_BACK,         false);
   ObjectSetInteger(0, objName, OBJPROP_ZORDER,       10);
  }

void CreateEditBox(const string name, const string text, int x, int y, int w, int h, color bg, color clr, color border, int fontSize)
  {
   string objName = g_Prefix + name;
   ObjectDelete(0, objName);
   ObjectCreate(0, objName, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE,    x);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE,    y);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE,        w);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE,        h);
   ObjectSetString(0,  objName, OBJPROP_TEXT,         text);
   ObjectSetString(0,  objName, OBJPROP_FONT,         "Segoe UI Bold");
   ObjectSetInteger(0, objName, OBJPROP_FONTSIZE,     fontSize);
   ObjectSetInteger(0, objName, OBJPROP_COLOR,        clr);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR,      bg);
   ObjectSetInteger(0, objName, OBJPROP_BORDER_COLOR, border);
   ObjectSetInteger(0, objName, OBJPROP_ALIGN,        ALIGN_CENTER);
   ObjectSetInteger(0, objName, OBJPROP_CORNER,       CORNER_LEFT_UPPER);
   ObjectSetInteger(0, objName, OBJPROP_SELECTABLE,   false);
   ObjectSetInteger(0, objName, OBJPROP_BACK,         false);
   ObjectSetInteger(0, objName, OBJPROP_ZORDER,       10);
  }
//+------------------------------------------------------------------+