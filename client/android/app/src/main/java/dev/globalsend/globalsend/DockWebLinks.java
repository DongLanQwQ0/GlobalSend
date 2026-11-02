package dev.globalsend.globalsend;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.text.Layout;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.style.ForegroundColorSpan;
import android.text.style.UnderlineSpan;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Link taps share the card's normal click/long-press path, not text selection. */
final class DockWebLinks {
    static final class Link {
        final int start,end;final String label;final Uri uri;
        Link(int start,String label,Uri uri){this.start=start;end=start+label.length();this.label=label;this.uri=uri;}
    }
    private static final Pattern CANDIDATE=Pattern.compile("(?:https?://|www\\.)[^\\s<>\"'，。；！？、【】《》“”‘’（）]+",Pattern.CASE_INSENSITIVE);
    private static final Pattern HOST_PROSE=Pattern.compile("^(?:\\[[0-9a-z:.%_-]+\\]|(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,63}|(?:\\d{1,3}\\.){3}\\d{1,3}|localhost)(?::\\d+)?(?=[\\u3400-\\u9fff\\uf900-\\ufaff])",Pattern.CASE_INSENSITIVE);
    static List<Link> find(String text) {
        List<Link> links=new ArrayList<>();if(text==null)return links;
        Matcher found=CANDIDATE.matcher(text);
        while(found.find()) {
            String label=found.group();
            int authority=label.toLowerCase(Locale.ROOT).startsWith("www.")?0:label.indexOf("://")+3;
            String host=label.substring(authority).split("[/?#]",2)[0];Matcher prose=HOST_PROSE.matcher(host);
            if(prose.find())label=label.substring(0,authority+prose.end());
            String before;
            do {
                before=label;label=label.replaceFirst("[.,;:!?]+$","");
                for(String pair:new String[]{"()","[]","{}"}) {
                    char open=pair.charAt(0),close=pair.charAt(1);
                    while(label.endsWith(String.valueOf(close)) && count(label,close)>count(label,open))label=label.substring(0,label.length()-1);
                }
            } while(!label.equals(before));
            Uri uri=Uri.parse(label.toLowerCase(Locale.ROOT).startsWith("www.")?"https://"+label:label).normalizeScheme();
            String scheme=uri.getScheme();
            if(uri.getHost()!=null && !uri.getHost().isEmpty() && ("https".equalsIgnoreCase(scheme)||"http".equalsIgnoreCase(scheme)))
                links.add(new Link(found.start(),label,uri));
        }
        return links;
    }
    private static int count(String text,char value) {int count=0;for(int i=0;i<text.length();i++)if(text.charAt(i)==value)count++;return count;}
    static void decorate(TextView text,int color) {
        SpannableString value=new SpannableString(text.getText());
        for(Link link:find(value.toString())) {
            value.setSpan(new ForegroundColorSpan(color),link.start,link.end,Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            value.setSpan(new UnderlineSpan(),link.start,link.end,Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        }
        // No MovementMethod: it would take the card's long press and scrolling.
        text.setText(value);
    }
    static Uri at(TextView text,float x,float y) {
        if(text==null || text.getLayout()==null || Float.isNaN(x) || Float.isNaN(y))return null;
        Layout layout=text.getLayout();x=x-text.getTotalPaddingLeft()+text.getScrollX();
        y=y-text.getTotalPaddingTop()+text.getScrollY();
        if(y<0 || y>=layout.getHeight())return null;
        int line=layout.getLineForVertical((int)y);
        if(x<layout.getLineLeft(line) || x>layout.getLineRight(line))return null;
        int offset=layout.getOffsetForHorizontal(line,x);
        int cut=layout.getEllipsisCount(line)>0?layout.getLineStart(line)+layout.getEllipsisStart(line):Integer.MAX_VALUE;
        if(offset>=cut)return null;
        for(Link link:find(text.getText().toString()))if(offset>=link.start && offset<link.end)return link.uri;
        return null;
    }
    static void open(Context context,Uri uri) {
        context.startActivity(new Intent(Intent.ACTION_VIEW,uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    }
}
