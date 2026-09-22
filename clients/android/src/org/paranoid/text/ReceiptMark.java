package org.paranoid.text;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.view.View;
import org.json.JSONObject;

/** Draws REQ-MSG-003's three states; geometry uses dp, never font glyphs or baselines. */
public final class ReceiptMark extends View {
    private final String mark;
    private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path=new Path();
    private final float density;

    public ReceiptMark(Context context,JSONObject message,int color){
        super(context);
        mark=MessagePresentation.mark(message);
        density=context.getResources().getDisplayMetrics().density;
        paint.setColor(color);paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(1.5f);
        paint.setStrokeCap(Paint.Cap.ROUND);paint.setStrokeJoin(Paint.Join.ROUND);
        setMinimumWidth(Math.round(24*density));setMinimumHeight(Math.round(18*density));
        setContentDescription(MessagePresentation.delivery(message));
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_YES);
    }

    @Override protected void onDraw(Canvas canvas){
        super.onDraw(canvas);
        canvas.save();
        canvas.translate((getWidth()-19*density)/2,(getHeight()-12*density)/2);
        canvas.scale(density,density);
        if("queued".equals(mark)){
            canvas.drawCircle(9.5f,6,4.5f,paint);
            canvas.drawLine(9.5f,3,9.5f,6,paint);
            canvas.drawLine(9.5f,6,12,6,paint);
        }else{
            path.reset();
            tick("delivered".equals(mark)?0:2.5f);
            if("delivered".equals(mark))tick(5);
            canvas.drawPath(path,paint);
        }
        canvas.restore();
    }
    private void tick(float x){path.moveTo(x+1,6);path.lineTo(x+5,10);path.lineTo(x+13,2);}
}
