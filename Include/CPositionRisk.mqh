//+------------------------------------------------------------------+
//|                                          CPositionRisk.mqh       |
//|              Position sizing helper for risk-based trading      |
//+------------------------------------------------------------------+
#property copyright "Eng.Alhassan Ali Mubarak Bahbah"
#property version   "1.00"

class CPositionRisk
  {
private:
   double            m_riskPercent;

public:
                     CPositionRisk(void) : m_riskPercent(1.0) {}

   void              SetRiskPercent(const double riskPercent)
     {
      m_riskPercent = MathMax(0.0, riskPercent);
     }

   double            GetRiskPercent(void) const
     {
      return m_riskPercent;
     }

   double            NormalizeVolume(const string symbol, double volume) const
     {
      double minVolume  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      double maxVolume  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      double volumeStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

      if(minVolume <= 0.0 || maxVolume <= 0.0 || volumeStep <= 0.0)
         return 0.0;

      volume = MathMax(minVolume, MathMin(maxVolume, volume));
      double steps = MathFloor((volume - minVolume) / volumeStep + 1e-8);
      double normalized = minVolume + (steps * volumeStep);
      return NormalizeDouble(MathMax(minVolume, MathMin(maxVolume, normalized)), 8);
     }

   double            CalculateVolume(const string symbol,
                                     const double entryPrice,
                                     const double stopLossPrice) const
     {
      if(m_riskPercent <= 0.0 || entryPrice <= 0.0 || stopLossPrice <= 0.0)
         return 0.0;

      double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
      double priceRisk = MathAbs(entryPrice - stopLossPrice);

      if(tickSize <= 0.0 || tickValue <= 0.0 || balance <= 0.0 || priceRisk <= 0.0)
         return 0.0;

      double riskAmount = balance * (m_riskPercent / 100.0);
      double lossPerLot = (priceRisk / tickSize) * tickValue;
      if(lossPerLot <= 0.0)
         return 0.0;

      return NormalizeVolume(symbol, riskAmount / lossPerLot);
     }
  };
