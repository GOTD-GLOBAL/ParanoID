package org.paranoid.text;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.os.Bundle;
import android.view.View;
import java.util.Arrays;
import org.json.JSONObject;
import org.json.JSONArray;

/** Isolated no-network APK: real Canvas and preferences, not the messenger app. */
public final class ReceiptViewInstrumentation extends Instrumentation {
    private Bundle arguments;
    @Override public void onCreate(Bundle args){super.onCreate(args);arguments=args;start();}
    private static void check(boolean value,String message){if(!value)throw new AssertionError(message);}
    private static JSONObject message(boolean accepted,boolean delivered)throws Exception{
        return new JSONObject().put("author","me").put("accepted",accepted).put("delivered",delivered);
    }
    private static int[] pixels(Context context,JSONObject message)throws Exception{
        ReceiptMark view=new ReceiptMark(context,message,Color.BLACK);
        check(MessagePresentation.delivery(message).contentEquals(view.getContentDescription()),"accessible state label");
        check(view.getImportantForAccessibility()==View.IMPORTANT_FOR_ACCESSIBILITY_YES,"accessible mark");
        int width=Math.round(24*context.getResources().getDisplayMetrics().density);
        int height=Math.round(18*context.getResources().getDisplayMetrics().density);
        view.measure(View.MeasureSpec.makeMeasureSpec(width,View.MeasureSpec.EXACTLY),
                     View.MeasureSpec.makeMeasureSpec(height,View.MeasureSpec.EXACTLY));
        view.layout(0,0,width,height);
        Bitmap bitmap=Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888);
        view.draw(new Canvas(bitmap));
        int[] result=new int[width*height];bitmap.getPixels(result,0,width,0,0,width,height);bitmap.recycle();
        int ink=0;for(int pixel:result)if(Color.alpha(pixel)>0)ink++;
        check(ink>0,"actual Canvas has painted pixels");
        return result;
    }
    private void exercise()throws Exception{
        Context context=getTargetContext();
        JSONObject delivered=message(true,true);
        JSONObject dialog=new JSONObject().put("own","me").put("messages",new JSONArray().put(delivered));
        if("reopen".equals(arguments.getString("phase"))){
            check(!ReceiptHint.isPending(context),"dismissal survived process restart");
            check(!ReceiptHint.shouldShow(context,dialog),"hint stays hidden after restart");
            return;
        }
        // Only this disposable package's preferences are touched.
        context.getSharedPreferences("paranoid-receipt-hint-v1",Context.MODE_PRIVATE).edit().clear().commit();
        check(ReceiptHint.isPending(context),"fresh preference pending");
        check(ReceiptHint.shouldShow(context,dialog),"first own delivery shows hint");
        check(!ReceiptHint.shouldShow(context,new JSONObject().put("own","me").put("messages",new JSONArray().put(message(true,false)))),"no premature hint");
        for(int dpi:new int[]{160,320}){
            Configuration normal=new Configuration(context.getResources().getConfiguration());normal.densityDpi=dpi;normal.fontScale=1;
            Configuration large=new Configuration(normal);large.fontScale=2;
            Context a=context.createConfigurationContext(normal),b=context.createConfigurationContext(large);
            int[] queued=pixels(a,message(false,false)),stored=pixels(a,message(true,false)),done=pixels(a,delivered);
            check(!Arrays.equals(queued,stored)&&!Arrays.equals(stored,done)&&!Arrays.equals(queued,done),"three distinct drawings");
            check(Arrays.equals(queued,pixels(b,message(false,false))),"clock independent of text font scale");
            check(Arrays.equals(stored,pixels(b,message(true,false))),"one mark independent of text font scale");
            check(Arrays.equals(done,pixels(b,delivered)),"two marks independent of text font scale");
        }
        ReceiptHint.dismiss(context);
        check(!ReceiptHint.shouldShow(context,dialog),"dismiss immediately hides hint");
        ReceiptHint.dismiss(context);
        check(!ReceiptHint.isPending(context),"dismiss idempotent");
        // Ensure the async preference write completes before the runner force-stops
        // this synthetic package to exercise a normal persisted-process restart.
        context.getSharedPreferences("paranoid-receipt-hint-v1",Context.MODE_PRIVATE).edit().commit();
    }
    @Override public void onStart(){
        final Throwable[] failure={null};
        runOnMainSync(()->{try{exercise();}catch(Throwable error){failure[0]=error;}});
        Bundle result=new Bundle();
        if(failure[0]!=null){result.putString("stream","FAIL: "+failure[0]);finish(Activity.RESULT_CANCELED,result);}
        else {result.putString("stream","PASS receipt Canvas/labels/hint "+arguments.getString("phase"));finish(Activity.RESULT_OK,result);}
    }
}
