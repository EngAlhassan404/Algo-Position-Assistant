//+------------------------------------------------------------------+
//|                                            CSuperTrendEngine.mqh |
//|                                  Internal SuperTrend Calculator  |
//+------------------------------------------------------------------+
#property copyright "Eng.Alhassan Ali Mubarak Bahbah"
#property version   "2.00"

class CSuperTrendEngine
  {
private:
   int               m_atrPeriod;
   double            m_multiplier;
   int               m_atrHandle;
   string            m_symbol;
   ENUM_TIMEFRAMES   m_period;

   // دالة داخلية خاصة لحساب النطاقات والمصفوفات لتجنب تكرار الكود
   bool              ComputeBuffers(int shift, double &upBuf[], double &dnBuf[], int &trend[])
     {
      if(m_atrHandle == INVALID_HANDLE) return false;

      // جلب عدد كافٍ من الشموع لضمان استقرار حسابات السوبر ترند
      int fetchBars = m_atrPeriod + shift + 200; 
      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copiedRates = CopyRates(m_symbol, m_period, 0, fetchBars, rates);
      if(copiedRates <= m_atrPeriod + shift) return false;

      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(m_atrHandle, 0, 0, fetchBars, atr) <= m_atrPeriod + shift) return false;

      int total = copiedRates;
      ArrayResize(upBuf, total);
      ArrayResize(dnBuf, total);
      ArrayResize(trend, total);

      int startIdx = total - m_atrPeriod - 1;
      trend[startIdx + 1] = 1;

      for(int i = startIdx; i >= 0; i--)
        {
         double src = (rates[i].high + rates[i].low) / 2.0;
         double upBasic = src - (m_multiplier * atr[i]);
         double dnBasic = src + (m_multiplier * atr[i]);

         double upPrev = (i < total - 1) ? upBuf[i+1] : upBasic;
         double dnPrev = (i < total - 1) ? dnBuf[i+1] : dnBasic;

         if(rates[i+1].close > upPrev)
            upBuf[i] = MathMax(upBasic, upPrev);
         else
            upBuf[i] = upBasic;

         if(rates[i+1].close < dnPrev)
            dnBuf[i] = MathMin(dnBasic, dnPrev);
         else
            dnBuf[i] = dnBasic;

         int prevTrend = (i < total - 1) ? trend[i+1] : 1;
         int currentTrend = prevTrend;

         if(prevTrend == -1 && rates[i].close > dnBuf[i+1])
            currentTrend = 1;
         else if(prevTrend == 1 && rates[i].close < upBuf[i+1])
            currentTrend = -1;

         trend[i] = currentTrend;
        }
      return true;
     }

public:
                     CSuperTrendEngine(void) : m_atrPeriod(10), m_multiplier(3.0), m_atrHandle(INVALID_HANDLE) {}
                    ~CSuperTrendEngine(void) { Release(); }

   // دالة التهيئة
   bool              Init(string symbol, ENUM_TIMEFRAMES period, int atrPeriod, double multiplier)
     {
      m_symbol     = symbol;
      m_period     = period;
      m_atrPeriod  = atrPeriod;
      m_multiplier = multiplier;

      m_atrHandle = iATR(m_symbol, m_period, m_atrPeriod);
      return (m_atrHandle != INVALID_HANDLE);
     }

   // دالة تحرير الموارد
   void              Release(void)
     {
      if(m_atrHandle != INVALID_HANDLE)
        {
         IndicatorRelease(m_atrHandle);
         m_atrHandle = INVALID_HANDLE;
        }
     }

   // دالة تُرجِع قيمة المؤشر التقليدية واتجاه الترند في نفس الوقت
   double            GetSuperTrend(int shift, int &outTrendDirection)
     {
      double upBuf[], dnBuf[];
      int trend[];
      if(!ComputeBuffers(shift, upBuf, dnBuf, trend))
        {
         outTrendDirection = 0;
         return 0.0;
        }

      // تمرير اتجاه الترند للخارج
      outTrendDirection = trend[shift]; 
      
      // إرجاع القيمة بناءً على الاتجاه الرسمى
      return (trend[shift] == 1) ? upBuf[shift] : dnBuf[shift];
     }

   // دالة موجهة لإدارة وقف الخسارة المباشر والمستمر
   // تضمن إرجاع خط الدعم للشرائيات وخط المقاومة للبيعات بغض النظر عن حالة الاتجاه
   double            GetStopLossPrice(int shift, ENUM_POSITION_TYPE posType)
     {
      double upBuf[], dnBuf[];
      int trend[];
      if(!ComputeBuffers(shift, upBuf, dnBuf, trend))
         return 0.0;

      if(posType == POSITION_TYPE_BUY)
         return upBuf[shift];   // الخط السفلي لحماية صفقات الشراء
      else if(posType == POSITION_TYPE_SELL)
         return dnBuf[shift];   // الخط العلوي لحماية صفقات البيع

      return 0.0;
     }
  };